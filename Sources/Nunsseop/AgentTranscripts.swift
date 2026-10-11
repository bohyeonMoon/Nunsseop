import Foundation

/// How a session handles permissions. `standard` is the tool's default, which has no label.
enum AgentMode: Equatable {
    case standard, plan, acceptEdits, auto, dontAsk, bypass, fullAccess

    /// Claude Code's `permissionMode`; one it doesn't know is `standard`.
    init(claude raw: String) {
        switch raw {
        case "plan": self = .plan
        case "acceptEdits": self = .acceptEdits
        case "auto": self = .auto
        case "dontAsk": self = .dontAsk
        case "bypassPermissions": self = .bypass
        default: self = .standard
        }
    }

    var label: String? {
        switch self {
        case .standard: nil
        case .plan: String(localized: "Plan")
        case .acceptEdits: String(localized: "Auto-accept edits")
        case .auto: String(localized: "Auto")
        case .dontAsk: String(localized: "Don't ask")
        case .bypass: String(localized: "Bypass permissions")
        case .fullAccess: String(localized: "Full access")
        }
    }

    /// Nothing asks before it acts.
    var warns: Bool { self == .bypass || self == .fullAccess }
}

/// What a session's transcript on disk says about it, for the Agents tab. Only these four values are kept: the
/// hooks send no folder, model, token count or mode, and what the sessions say stays in the tools' own files.
struct AgentTranscript: Equatable {
    var cwd: String? = nil
    var model: String? = nil
    /// The context the last request used.
    var tokens: Int? = nil
    var mode: AgentMode? = nil

    /// Claude Code's lines carry `cwd` and, on assistant messages, `message.model` and `message.usage`, and on prompts
    /// and `permission-mode` lines the `permissionMode`; Codex's `session_meta` and `turn_context` carry `cwd` and
    /// `model`, `turn_context` also the sandbox and collaboration mode, and its `token_count` events the usage. The first
    /// folder is the one the session started in (the shell can move on later); for the rest the later line wins. A line
    /// that doesn't parse (a half-written last one, or the cut one a tail starts with) is skipped.
    static func parse(_ kind: AgentKind, head: Data = Data(), tail: Data) -> AgentTranscript {
        var result = AgentTranscript()
        for chunk in [head, tail] {
            for line in chunk.split(separator: 0x0A) {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                switch kind {
                case .claude: result.absorbClaude(object)
                case .codex: result.absorbCodex(object)
                }
            }
        }
        return result
    }

    private mutating func absorbClaude(_ object: [String: Any]) {
        // A subagent's lines are its own; synthetic messages (no reply was asked for) carry no real usage.
        guard object["isSidechain"] as? Bool != true else { return }
        if let raw = object["permissionMode"] as? String { mode = AgentMode(claude: raw) }
        if self.cwd == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty { self.cwd = cwd }
        guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
              let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>" else { return }
        self.model = model
        guard let usage = message["usage"] as? [String: Any] else { return }
        let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        guard keys.contains(where: { usage[$0] != nil }) else { return }
        tokens = keys.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
    }

    private mutating func absorbCodex(_ object: [String: Any]) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        switch object["type"] as? String {
        case "session_meta", "turn_context":
            if self.cwd == nil, let cwd = payload["cwd"] as? String, !cwd.isEmpty { self.cwd = cwd }
            if let model = payload["model"] as? String, !model.isEmpty { self.model = model }
            if object["type"] as? String == "turn_context" {
                let planning = (payload["collaboration_mode"] as? [String: Any])?["mode"] as? String == "plan"
                let sandbox = (payload["sandbox_policy"] as? [String: Any])?["type"] as? String
                mode = planning ? .plan : sandbox == "danger-full-access" ? .fullAccess : .standard
            }
        case "event_msg":
            // The first token_count of a session has no `info`; its input tokens include the cached ones.
            guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let input = (last["input_tokens"] as? NSNumber)?.intValue else { return }
            tokens = input
        default:
            break
        }
    }

    /// Where a read starts from the end of a file, and how far it widens when the last assistant message, token count
    /// or mode isn't in it (one line can be megabytes, and only a Claude Code prompt says the mode); the start of the file is read for the folder the session began in.
    static let firstWindow = 256 << 10
    static let lastWindow = 4 << 20
    static let headWindow = 128 << 10

    static func read(_ url: URL, kind: AgentKind) -> AgentTranscript? {
        guard let handle = try? FileHandle(forReadingFrom: url), let end = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        var window = UInt64(firstWindow)
        while true {
            let start = end > window ? end - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let tail = end == start ? Data() : try? handle.read(upToCount: Int(end - start)) else { return nil }
            var result = parse(kind, tail: tail)
            guard (result.model != nil && result.tokens != nil && result.mode != nil) || start == 0 || window >= UInt64(lastWindow) else {
                window *= 4
                continue
            }
            if start > 0, (try? handle.seek(toOffset: 0)) != nil,
               let head = try? handle.read(upToCount: min(Int(start), headWindow)),
               let first = parse(kind, head: head, tail: Data()).cwd {
                result.cwd = first
            }
            return result
        }
    }

    /// "claude-opus-5-5" as "Opus 5.5", and "claude-3-5-sonnet-20241022" as "Sonnet 3.5". Any other name is shown as is.
    static func modelLabel(_ raw: String) -> String {
        let name = raw.split(separator: "[").first.map(String.init) ?? raw
        guard name.hasPrefix("claude-") else { return name }
        var family: [String] = [], version: [String] = []
        for part in name.dropFirst("claude-".count).split(separator: "-") {
            if part.allSatisfy(\.isNumber) {
                // A date such as 20250805 isn't a version.
                if part.count <= 2 { version.append(String(part)) }
            } else if part != "latest" {
                family.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        guard !family.isEmpty else { return name }
        return (family + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
    }

    /// 842, 84k, 1.2M.
    static func tokensLabel(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(max(0, tokens))" }
        let thousands = (tokens + 500) / 1_000
        if thousands < 1_000 { return "\(thousands)k" }
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
}

/// Finds each session's transcript and keeps what it says. A value type, so a refresh can run off the main thread on
/// a copy: the files can be large and the folders many.
struct AgentTranscripts {
    struct Key: Hashable {
        let kind: AgentKind
        let session: String
    }

    private struct Entry {
        var url: URL?
        /// When it was last looked for, to retry a missing file only now and then.
        var checked: Date
        var modified: Date?
        var size: Int
        var transcript: AgentTranscript?
    }

    /// How long a transcript that wasn't found waits before it is looked for again.
    static let retryInterval: TimeInterval = 30
    private var entries: [Key: Entry] = [:]

    func transcript(_ key: Key) -> AgentTranscript? { entries[key]?.transcript }

    /// Brings the transcripts of `keys` up to date: a file is read again only when its size or time changed, one
    /// that is missing is looked for every `retryInterval`, and sessions no longer listed are forgotten.
    mutating func refresh(_ keys: Set<Key>, home: URL, now: Date = .now) {
        entries = entries.filter { keys.contains($0.key) }
        for key in keys where Self.isSafe(key.session) {
            var entry = entries[key] ?? Entry(url: nil, checked: .distantPast, modified: nil, size: 0, transcript: nil)
            if let url = entry.url {
                if let stamp = Self.stamp(url) {
                    if stamp.modified != entry.modified || stamp.size != entry.size {
                        entry.transcript = AgentTranscript.read(url, kind: key.kind)
                        (entry.modified, entry.size) = stamp
                    }
                    entries[key] = entry
                    continue
                }
                entry = Entry(url: nil, checked: .distantPast, modified: nil, size: 0, transcript: nil)
            }
            guard now.timeIntervalSince(entry.checked) >= Self.retryInterval else { continue }
            entry.checked = now
            if let url = Self.locate(key, home: home), let stamp = Self.stamp(url) {
                entry.url = url
                (entry.modified, entry.size) = stamp
                entry.transcript = AgentTranscript.read(url, kind: key.kind)
            }
            entries[key] = entry
        }
    }

    /// Not through `URL.resourceValues`, which keeps the first answer for as long as the URL lives.
    private static func stamp(_ url: URL) -> (modified: Date, size: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int else { return nil }
        return (modified, size)
    }

    /// Session ids come from a hook's headers or herdr's socket; only plain ones are turned into file names.
    static func isSafe(_ session: String) -> Bool {
        !session.isEmpty && session.count <= 64 && session.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Claude Code keeps `~/.claude/projects/<folder encoded in a name>/<session>.jsonl`. The folder can change in a
    /// session, so every project folder is looked in, and the newest file wins. Codex keeps
    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session>.jsonl`, looked for from the newest day.
    static func locate(_ key: Key, home: URL) -> URL? {
        let files = FileManager.default
        func children(_ url: URL) -> [URL] {
            (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        switch key.kind {
        case .claude:
            let candidates = children(home.appendingPathComponent(".claude/projects"))
                .map { $0.appendingPathComponent("\(key.session).jsonl") }
                .filter { files.fileExists(atPath: $0.path) }
            return candidates.max { (stamp($0)?.modified ?? .distantPast) < (stamp($1)?.modified ?? .distantPast) }
        case .codex:
            let newestFirst = { (urls: [URL]) in urls.sorted { $0.lastPathComponent > $1.lastPathComponent } }
            for year in newestFirst(children(home.appendingPathComponent(".codex/sessions"))) {
                for month in newestFirst(children(year)) {
                    for day in newestFirst(children(month)) {
                        // rollout-YYYY-MM-DDThh-mm-ss-<session>.jsonl: the whole name, not just its end.
                        let match = children(day).first {
                            let name = $0.lastPathComponent
                            return name.hasPrefix("rollout-") && name.hasSuffix("-\(key.session).jsonl")
                                && name.count == "rollout-".count + 19 + "-.jsonl".count + key.session.count
                        }
                        if let match { return match }
                    }
                }
            }
            return nil
        }
    }
}
