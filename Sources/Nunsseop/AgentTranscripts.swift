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

/// What a session's transcript on disk says about it, for the Agents tab. Only these five values are kept: the
/// hooks send no folder, model, token count, mode or name, and what the sessions say stays in the tools' own files.
struct AgentTranscript: Equatable {
    var cwd: String? = nil
    var model: String? = nil
    /// The context the last request used.
    var tokens: Int? = nil
    var mode: AgentMode? = nil
    /// What the user (or the tool) called the session; not part of `parse`, which reads a window of the file.
    var name: String? = nil

    /// A name for display: control characters and newlines as spaces, whitespace collapsed, trimmed, at most 80
    /// characters; nil when nothing is left.
    static func cleanName(_ raw: String) -> String? {
        let spaced = String(String.UnicodeScalarView(raw.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
        let collapsed = spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let capped = String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }

    /// Claude Code's lines carry `cwd` and, on assistant messages, `message.model` and `message.usage`, and on prompts
    /// and `permission-mode` lines the `permissionMode`; Codex's `session_meta` and `turn_context` carry `cwd` and
    /// `model`, `turn_context` also the sandbox and collaboration mode, and its `token_count` events the usage. The first
    /// folder is the one the session started in (the shell can move on later); for the rest the later line wins. A line
    /// that doesn't parse (a half-written last one, or the cut one a tail starts with) is skipped. The pi family's `session` header
    /// carries the folder (and, for omp and gjc, a title); `model_change` the model; assistant messages their model and usage.
    static func parse(_ kind: AgentKind, head: Data = Data(), tail: Data) -> AgentTranscript {
        var result = AgentTranscript()
        for chunk in [head, tail] {
            for line in chunk.split(separator: 0x0A) {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                switch kind {
                case .claude: result.absorbClaude(object)
                case .codex: result.absorbCodex(object)
                case .pi, .omp, .gjc, .omo: result.absorbPi(object)
                // OpenCode keeps no file to read; its database is (see `OpenCodeDB`).
                case .opencode: break
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

    private mutating func absorbPi(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "session":
            if self.cwd == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty { self.cwd = cwd }
            if name == nil, let title = (object["title"] as? String).flatMap(Self.cleanName) { name = title }
        case "title":
            // omp's first line, rewritten as the title changes: newer than the header's, whichever comes first.
            if let title = (object["title"] as? String).flatMap(Self.cleanName) { name = title }
        case "model_change":
            // `modelId` in pi and omo, `provider/model` in omp and gjc.
            if let model = (object["modelId"] as? String) ?? (object["model"] as? String).map({ String($0.split(separator: "/").last ?? "") }),
               !model.isEmpty { self.model = model }
        case "message":
            guard let message = object["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            if let model = message["model"] as? String, !model.isEmpty { self.model = model }
            // A failed request has no usage; the context is what the last real one sent, cached or not.
            guard let usage = message["usage"] as? [String: Any] else { return }
            let context = ["input", "cacheRead", "cacheWrite"].reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
            if context > 0 { tokens = context }
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
            guard (result.model != nil && result.tokens != nil && (result.mode != nil || !kind.reportsMode)) || start == 0
                    || window >= UInt64(lastWindow) else {
                window *= 4
                continue
            }
            if start > 0, (try? handle.seek(toOffset: 0)) != nil, let head = try? handle.read(upToCount: min(Int(start), headWindow)) {
                let first = parse(kind, head: head, tail: Data())
                if let cwd = first.cwd { result.cwd = cwd }
                if result.name == nil { result.name = first.name }
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

/// A session's name. In Claude Code's files `custom-title` lines (from /rename) win over `agent-name` ones, those over the
/// automatic `ai-title` ones, the latest of each kind; in the pi family's the latest `session_info` (pi, omo) or `title_change`
/// (omp, gjc) line. They can sit anywhere in a file of tens of megabytes, so the file is read whole once and after that only
/// what was appended.
struct AgentNameScan: Equatable {
    enum Family: Equatable {
        case claude, pi

        var markers: [[UInt8]] {
            (self == .claude ? ["custom-title", "agent-name", "ai-title"] : ["session_info", "title_change"]).map { Array($0.utf8) }
        }
    }

    let family: Family
    var custom: String?
    var agent: String?
    var ai: String?
    /// The start of the first line not yet read whole: a line still being written is read again once it is finished.
    var offset: UInt64 = 0
    /// The bytes just before `offset`, which tell a file that was replaced from one that grew.
    var anchor = Data()

    var name: String? { custom ?? agent ?? ai }

    static let chunk = 4 << 20
    private static let anchorLength = 64

    init(family: Family = .claude) { self.family = family }

    /// Reads from `offset` to the end of the file in pieces of `size` bytes; a smaller or different file is read from the start.
    mutating func advance(_ url: URL, chunk size: Int = AgentNameScan.chunk) {
        guard let handle = try? FileHandle(forReadingFrom: url), let end = try? handle.seekToEnd() else { return }
        defer { try? handle.close() }
        if offset > end || !anchorHolds(handle) { self = AgentNameScan(family: family) }
        guard (try? handle.seek(toOffset: offset)) != nil else { return }
        let markers = family.markers
        let longest = markers.map(\.count).max() ?? 0
        var position = offset
        var lineStart = offset
        // A line that has no marker keeps only its last bytes, for a marker that straddles two pieces. When the marker
        // then turns up, the line's start is gone and the line is read again from the file once its end is known.
        var line = Data()
        var marked = false
        var truncated = false
        func take(_ piece: UnsafeRawBufferPointer, ended: Bool) {
            if marked {
                if !truncated { line.append(contentsOf: piece) }
                return
            }
            let keep = longest - 1
            if line.isEmpty, !Self.hasMarker(piece, markers) {
                if !ended {
                    line = Data(piece.suffix(keep))
                    truncated = piece.count > keep
                }
                return
            }
            line.append(contentsOf: piece)
            if Self.hasMarker(line, markers) {
                marked = true
                if truncated { line = Data() }
            } else if ended {
                line = Data()
            } else {
                truncated = truncated || line.count > keep
                line = Data(line.suffix(keep))
            }
        }
        func finish(at lineEnd: UInt64) {
            if marked {
                if truncated, let here = try? handle.offset(), (try? handle.seek(toOffset: lineStart)) != nil {
                    line = (try? handle.read(upToCount: Int(lineEnd - lineStart))) ?? Data()
                    try? handle.seek(toOffset: here)
                }
                absorb(line)
            }
            line = Data()
            marked = false
            truncated = false
        }
        while position < end {
            guard let data = try? handle.read(upToCount: Int(min(UInt64(max(1, size)), end - position))), !data.isEmpty else { break }
            data.withUnsafeBytes { raw in
                var start = 0
                while start < raw.count {
                    let rest = UnsafeRawBufferPointer(rebasing: raw[start...])
                    if let found = memchr(rest.baseAddress, 0x0A, rest.count) {
                        let length = found - UnsafeMutableRawPointer(mutating: rest.baseAddress!)
                        take(UnsafeRawBufferPointer(rebasing: rest[..<length]), ended: true)
                        finish(at: position + UInt64(start + length))
                        start += length + 1
                        lineStart = position + UInt64(start)
                    } else {
                        take(rest, ended: false)
                        start = raw.count
                    }
                }
            }
            position += UInt64(data.count)
        }
        // A last line without its newline is used now and read again when it is finished.
        finish(at: end)
        offset = lineStart
        anchor = Self.bytes(handle, before: offset)
    }

    private func anchorHolds(_ handle: FileHandle) -> Bool { offset == 0 || Self.bytes(handle, before: offset) == anchor }

    private static func bytes(_ handle: FileHandle, before offset: UInt64) -> Data {
        let length = min(UInt64(anchorLength), offset)
        guard length > 0, (try? handle.seek(toOffset: offset - length)) != nil else { return Data() }
        return (try? handle.read(upToCount: Int(length))) ?? Data()
    }

    private static func hasMarker(_ bytes: Data, _ markers: [[UInt8]]) -> Bool { bytes.withUnsafeBytes { hasMarker($0, markers) } }

    private static func hasMarker(_ bytes: UnsafeRawBufferPointer, _ markers: [[UInt8]]) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return markers.contains { marker in marker.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, marker.count) != nil } }
    }

    private mutating func absorb(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        func value(_ key: String) -> String? { (object[key] as? String).flatMap(AgentTranscript.cleanName) }
        switch object["type"] as? String {
        case "custom-title": custom = value("customTitle") ?? custom
        case "agent-name": agent = value("agentName") ?? agent
        case "ai-title": ai = value("aiTitle") ?? ai
        case "session_info": custom = value("name") ?? custom
        case "title_change": custom = value("title") ?? custom
        default: break
        }
    }
}

/// Codex's `session_index.jsonl`: one line per rename, the last line for a session id being its name.
struct CodexSessionNames {
    private(set) var names: [String: String] = [:]
    private struct Stamp: Equatable {
        let path: String
        let modified: Date
        let size: Int
    }
    private var stamp: Stamp?

    /// Reads the index again only when its size or time changed.
    mutating func refresh(home: URL) {
        let file = home.appendingPathComponent(".codex/session_index.jsonl")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int else {
            self = CodexSessionNames()
            return
        }
        let next = Stamp(path: file.path, modified: modified, size: size)
        guard next != stamp else { return }
        stamp = next
        names = (try? Data(contentsOf: file)).map(Self.parse) ?? [:]
    }

    static func parse(_ data: Data) -> [String: String] {
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = object["id"] as? String else { continue }
            names[id] = (object["thread_name"] as? String).flatMap(AgentTranscript.cleanName)
        }
        return names
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
        var scan = AgentNameScan()

        init(kind: AgentKind) {
            (url, checked, modified, size, transcript) = (nil, .distantPast, nil, 0, nil)
            scan = AgentNameScan(family: kind.isPiFamily ? .pi : .claude)
        }
    }

    /// How long a transcript that wasn't found waits before it is looked for again.
    static let retryInterval: TimeInterval = 30
    /// How long OpenCode's database is left alone after a look: it has no file whose size and time tell a change.
    static let databaseInterval: TimeInterval = 5
    private var entries: [Key: Entry] = [:]
    private var codexNames = CodexSessionNames()

    func transcript(_ key: Key) -> AgentTranscript? { entries[key]?.transcript }

    /// Brings the transcripts of `keys` up to date: a file is read again only when its size or time changed, one
    /// that is missing is looked for every `retryInterval`, and sessions no longer listed are forgotten. Names come from
    /// the transcript's title lines (read on from where the last refresh stopped) or from Codex's session index.
    mutating func refresh(_ keys: Set<Key>, home: URL, now: Date = .now) {
        entries = entries.filter { keys.contains($0.key) }
        if keys.contains(where: { $0.kind == .codex }) { codexNames.refresh(home: home) }
        for key in keys where Self.isSafe(key.session) {
            var entry = entries[key] ?? Entry(kind: key.kind)
            if key.kind == .opencode {
                guard now.timeIntervalSince(entry.checked) >= Self.databaseInterval else { continue }
                entry.checked = now
                entry.transcript = OpenCodeDB.transcript(session: key.session, home: home) ?? entry.transcript
                entries[key] = entry
                continue
            }
            if let url = entry.url {
                if let stamp = Self.stamp(url) {
                    if stamp.modified != entry.modified || stamp.size != entry.size {
                        load(&entry, key: key, url: url)
                        (entry.modified, entry.size) = stamp
                    }
                    entries[key] = named(entry, key)
                    continue
                }
                entry = Entry(kind: key.kind)
            }
            guard now.timeIntervalSince(entry.checked) >= Self.retryInterval else { continue }
            entry.checked = now
            if let url = Self.locate(key, home: home), let stamp = Self.stamp(url) {
                entry.url = url
                (entry.modified, entry.size) = stamp
                load(&entry, key: key, url: url)
            }
            entries[key] = named(entry, key)
        }
    }

    private func load(_ entry: inout Entry, key: Key, url: URL) {
        entry.transcript = AgentTranscript.read(url, kind: key.kind)
        if key.kind != .codex { entry.scan.advance(url) }
    }

    /// The name from the title lines (the pi family's header title when there are none) or Codex's index.
    private func named(_ entry: Entry, _ key: Key) -> Entry {
        var entry = entry
        let name = key.kind == .codex ? codexNames.names[key.session] : entry.scan.name ?? entry.transcript?.name
        entry.transcript?.name = name
        return entry
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
    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session>.jsonl`, looked for from the newest day. The pi family's are in
    /// `PiSessions`; OpenCode has none.
    static func locate(_ key: Key, home: URL) -> URL? {
        let files = FileManager.default
        func children(_ url: URL) -> [URL] {
            (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        switch key.kind {
        case .pi, .omp, .gjc, .omo:
            return PiSessions.locate(key.kind, session: key.session, home: home)
        case .opencode:
            return nil
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
