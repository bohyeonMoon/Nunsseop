import Foundation

/// What Claude Code and Codex did in one week, added up from the session logs they keep on this Mac. Nothing is sent anywhere.
struct WeekRecap: Equatable, Sendable {
    struct Longest: Equatable, Sendable {
        let duration: TimeInterval
        let start: Date
        /// The session's name, else its folder.
        let title: String?
    }

    /// From Monday 00:00 to the next Monday 00:00.
    let week: DateInterval
    var working: TimeInterval = 0
    /// The week before's working time, for the change.
    var workingBefore: TimeInterval = 0
    var claudeSessions = 0
    var codexSessions = 0
    var claudeTokens = 0
    var codexTokens = 0
    var added = 0
    var removed = 0
    var files = 0
    /// Working time per project folder; a project with sessions but no working time is there with 0.
    var projects: [String: TimeInterval] = [:]
    var longest: Longest?
    /// Working time per day, Monday first.
    var days = [TimeInterval](repeating: 0, count: 7)

    var sessions: Int { claudeSessions + codexSessions }
    var tokens: Int { claudeTokens + codexTokens }
    var isEmpty: Bool { sessions == 0 }

    /// The project with the most working time and its share of all of it.
    var topProject: (name: String, share: Double)? {
        guard working > 0, let top = projects.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }), top.value > 0 else { return nil }
        return (top.key, top.value / working)
    }

    /// The day (0 is Monday) with the most working time; the earlier one when two tie.
    var busiestDay: Int? {
        guard let top = days.max(), top > 0 else { return nil }
        return days.firstIndex(of: top)
    }

    /// Entries further apart than this are not one stretch of work.
    static let workGap: TimeInterval = 5 * 60

    /// Monday 00:00 of the week `date` is in.
    static func weekStart(of date: Date, calendar: Calendar) -> Date {
        var monday = calendar
        monday.firstWeekday = 2
        monday.minimumDaysInFirstWeek = 4
        return monday.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// The week before the one `now` is in.
    static func lastWeek(before now: Date, calendar: Calendar) -> DateInterval {
        let this = weekStart(of: now, calendar: calendar)
        return DateInterval(start: calendar.date(byAdding: .day, value: -7, to: this) ?? this.addingTimeInterval(-7 * 86_400), end: this)
    }

    /// The week before the one `now` is in, from Claude Code's logs (`~/.claude/projects`) and Codex's (`~/.codex/sessions`) under `home`.
    /// Work is counted per session: a gap of at most `workGap` between two entries is time the agent worked. Sessions a program started
    /// with the Agent SDK are left out, as the Agents tab leaves them out.
    static func read(home: URL, now: Date, calendar: Calendar = .current) -> WeekRecap {
        var reader = Reader(home: home, week: lastWeek(before: now, calendar: calendar), calendar: calendar)
        let claude = AIUsageModel.files(under: home.appendingPathComponent(".claude/projects"), modifiedSince: reader.before) { $0.pathExtension == "jsonl" }
        let codex = AIUsageModel.files(under: home.appendingPathComponent(".codex/sessions"), modifiedSince: reader.before) {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
        }
        for (url, _) in claude.sorted(by: { $0.0.path < $1.0.path }) { reader.scan(url, tool: .claude) }
        for (url, _) in codex.sorted(by: { $0.0.path < $1.0.path }) { reader.scan(url, tool: .codex) }
        return reader.recap()
    }

    // MARK: Lines

    /// Lines in `new` that aren't in `old`, and the other way round; a line moved or repeated counts by how many times it occurs.
    static func lineChanges(old: String, new: String) -> (added: Int, removed: Int) {
        var counts: [Substring: Int] = [:]
        for line in lines(old) { counts[line, default: 0] -= 1 }
        for line in lines(new) { counts[line, default: 0] += 1 }
        return counts.values.reduce(into: (added: 0, removed: 0)) { total, count in
            if count > 0 { total.added += count } else { total.removed -= count }
        }
    }

    private static func lines(_ text: String) -> [Substring] {
        text.isEmpty ? [] : text.dropLast(text.hasSuffix("\n") ? 1 : 0).split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The lines an `apply_patch` input adds and removes and the files it names; its headers (`*** Update File: …`, `@@`) are neither.
    static func patchChanges(_ patch: String) -> (added: Int, removed: Int, paths: [String]) {
        var result = (added: 0, removed: 0, paths: [String]())
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("*** ") {
                for header in ["Add File: ", "Update File: ", "Delete File: "] where line.dropFirst(4).hasPrefix(header) {
                    result.paths.append(String(line.dropFirst(4 + header.count)))
                }
            } else if line.hasPrefix("+") {
                result.added += 1
            } else if line.hasPrefix("-") {
                result.removed += 1
            }
        }
        return result
    }

    // MARK: Reading

    private struct Session {
        let tool: AgentKind
        let id: String
        let file: URL
        var times: [Date] = []
        var cwd: String?
        var isProgram = false
        var added = 0
        var removed = 0
    }

    private struct Reader {
        let home: URL
        let week: DateInterval
        let calendar: Calendar
        /// Entries from the week before count for the change in working time only.
        let before: Date
        let iso = AIUsageModel.isoParser()
        var sessions: [String: Session] = [:]
        var paths = Set<String>()
        /// Tool calls and responses seen already, which a resumed or forked session's log repeats.
        var calls = Set<String>()
        var responses = Set<String>()
        var tokens: [AgentKind: Int] = [:]

        init(home: URL, week: DateInterval, calendar: Calendar) {
            self.home = home
            self.week = week
            self.calendar = calendar
            before = calendar.date(byAdding: .day, value: -7, to: week.start) ?? week.start.addingTimeInterval(-7 * 86_400)
        }

        mutating func scan(_ url: URL, tool: AgentKind) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            let name = url.deletingPathExtension().lastPathComponent
            // rollout-YYYY-MM-DDThh-mm-ss-<session>
            let fallback = tool == .claude ? name : String(name.dropFirst("rollout-".count + 19 + 1))
            var inWeek = false, program = false
            for line in data.split(separator: 0x0A) {
                autoreleasepool {
                    guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let stamp = (json["timestamp"] as? String).flatMap(iso), stamp >= before, stamp < week.end else { return }
                    inWeek = inWeek || stamp >= week.start
                    let id = tool == .claude ? json["sessionId"] as? String ?? fallback : fallback
                    let key = "\(tool.rawValue)|\(id)"
                    var session = sessions.removeValue(forKey: key) ?? Session(tool: tool, id: id, file: url)
                    defer { sessions[key] = session }
                    session.times.append(stamp)
                    if session.cwd == nil, let cwd = Self.folder(json, tool: tool) { session.cwd = cwd }
                    if (json["entrypoint"] as? String)?.hasPrefix("sdk") == true {
                        session.isProgram = true
                        program = true
                    }
                    guard stamp >= week.start else { return }
                    if tool == .claude { claudeEdits(json, into: &session) } else { codexEdits(json, into: &session) }
                }
            }
            guard inWeek, !program else { return }
            let records = tool == .claude ? AIUsageModel.claudeCodeRecords(data) : AIUsageModel.codexRecords(data)
            for record in records where record.date >= week.start && record.date < week.end && record.tokens > 0 {
                if let id = record.id, !responses.insert(id).inserted { continue }
                tokens[tool, default: 0] += record.tokens
            }
        }

        /// Claude Code puts the folder on every line; Codex on its `session_meta` and `turn_context` lines.
        private static func folder(_ json: [String: Any], tool: AgentKind) -> String? {
            let cwd: String?
            if tool == .claude {
                cwd = json["cwd"] as? String
            } else {
                cwd = ["session_meta", "turn_context"].contains(json["type"] as? String ?? "") ? (json["payload"] as? [String: Any])?["cwd"] as? String : nil
            }
            return cwd.flatMap { $0.isEmpty ? nil : $0 }
        }

        private mutating func claudeEdits(_ json: [String: Any], into session: inout Session) {
            guard json["type"] as? String == "assistant",
                  let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String, let input = block["input"] as? [String: Any],
                      let path = input["file_path"] as? String, (block["id"] as? String).map({ calls.insert($0).inserted }) ?? true else { continue }
                var changes: [(old: String, new: String)] = []
                switch name {
                case "Edit": changes = [(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "")]
                case "MultiEdit": changes = (input["edits"] as? [[String: Any]] ?? []).map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
                case "Write": changes = [("", input["content"] as? String ?? "")]
                default: continue
                }
                for change in changes {
                    let counts = WeekRecap.lineChanges(old: change.old, new: change.new)
                    session.added += counts.added
                    session.removed += counts.removed
                }
                paths.insert(path)
            }
        }

        private mutating func codexEdits(_ json: [String: Any], into session: inout Session) {
            guard json["type"] as? String == "response_item", let payload = json["payload"] as? [String: Any],
                  (payload["call_id"] as? String).map({ calls.insert($0).inserted }) ?? true else { return }
            let patch: String?
            switch payload["type"] as? String {
            case "custom_tool_call": patch = payload["name"] as? String == "apply_patch" ? payload["input"] as? String : nil
            case "function_call": patch = (payload["arguments"] as? String).flatMap(Self.embeddedPatch)
            default: patch = nil
            }
            guard let patch else { return }
            let counts = WeekRecap.patchChanges(patch)
            session.added += counts.added
            session.removed += counts.removed
            for path in counts.paths {
                paths.insert(path.hasPrefix("/") || session.cwd == nil ? path : "\(session.cwd ?? "")/\(path)")
            }
        }

        /// Older Codex runs `apply_patch` through its shell tool, with the patch inside the call's JSON arguments.
        private static func embeddedPatch(_ arguments: String) -> String? {
            func strings(_ value: Any) -> [String] {
                switch value {
                case let text as String: [text]
                case let list as [Any]: list.flatMap(strings)
                case let object as [String: Any]: object.values.flatMap(strings)
                default: []
                }
            }
            guard arguments.contains("*** Begin Patch"), let decoded = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) else { return nil }
            return strings(decoded).first { $0.contains("*** Begin Patch") }
        }

        // MARK: Adding up

        func recap() -> WeekRecap {
            var recap = WeekRecap(week: week)
            let reading = sessions.values.filter { !$0.isProgram }.sorted { ($0.tool.rawValue, $0.id) < ($1.tool.rawValue, $1.id) }
            var longest: (session: Session, duration: TimeInterval, start: Date)?
            for session in reading {
                let times = session.times.sorted()
                let split = times.firstIndex { $0 >= week.start } ?? times.count
                recap.workingBefore += Self.working(times[..<split])
                let inWeek = times[split...]
                guard let first = inWeek.first else { continue }
                if session.tool == .claude { recap.claudeSessions += 1 } else { recap.codexSessions += 1 }
                recap.added += session.added
                recap.removed += session.removed
                var duration: TimeInterval = 0
                for (a, b) in zip(inWeek, inWeek.dropFirst()) where b.timeIntervalSince(a) <= WeekRecap.workGap {
                    duration += b.timeIntervalSince(a)
                    let day = calendar.dateComponents([.day], from: week.start, to: calendar.startOfDay(for: a)).day ?? 0
                    recap.days[min(max(day, 0), 6)] += b.timeIntervalSince(a)
                }
                recap.working += duration
                if let project = session.cwd.flatMap(Self.project) { recap.projects[project, default: 0] += duration }
                if duration > (longest?.duration ?? 0) { longest = (session, duration, first) }
            }
            recap.claudeTokens = tokens[.claude] ?? 0
            recap.codexTokens = tokens[.codex] ?? 0
            recap.files = paths.count
            if let longest { recap.longest = .init(duration: longest.duration, start: longest.start, title: title(of: longest.session)) }
            return recap
        }

        private static func working(_ times: ArraySlice<Date>) -> TimeInterval {
            zip(times, times.dropFirst()).reduce(0) { total, pair in
                let gap = pair.1.timeIntervalSince(pair.0)
                return gap <= WeekRecap.workGap ? total + gap : total
            }
        }

        private static func project(_ cwd: String) -> String? {
            let name = (cwd as NSString).lastPathComponent
            return name == "/" || name.isEmpty ? nil : name
        }

        private func title(of session: Session) -> String? {
            var name: String?
            if session.tool == .claude {
                var scan = AgentNameScan()
                scan.advance(session.file)
                name = scan.name
            } else {
                var names = CodexSessionNames()
                names.refresh(home: home)
                name = names.names[session.id]
            }
            return name ?? session.cwd.flatMap(Self.project)
        }
    }
}
