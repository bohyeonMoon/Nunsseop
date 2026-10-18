import Foundation

/// What a coding agent did last, read from its transcript: the tool it used and on what. Edits keep their text, so the Agents tab
/// can show what changed.
struct AgentActivity: Equatable {
    enum Verb: Equatable {
        case read, edit, write, run, search, ask, delegate
        /// A tool with no verb of its own (an MCP tool, say), by the name the transcript gives it.
        case tool(String)

        var symbol: String {
            switch self {
            case .read: "doc.text"
            case .edit, .write: "pencil"
            case .run: "terminal"
            case .search: "magnifyingglass"
            case .ask: "questionmark.bubble"
            case .delegate: "person.2"
            case .tool: "wrench.and.screwdriver"
            }
        }

        var label: String {
            switch self {
            case .read: String(localized: "Read", comment: "What an agent did last: read a file")
            case .edit: String(localized: "Edited", comment: "What an agent did last: edited a file")
            case .write: String(localized: "Wrote", comment: "What an agent did last: wrote a file")
            case .run: String(localized: "Ran", comment: "What an agent did last: ran a command")
            case .search: String(localized: "Searched", comment: "What an agent did last: searched")
            case .ask: String(localized: "Asked", comment: "What an agent did last: asked you a question")
            case .delegate: String(localized: "Delegated", comment: "What an agent did last: handed a task to a subagent")
            case .tool(let name): name
            }
        }
    }

    /// One file change: the text before and after (a new file has none before).
    struct Edit: Equatable {
        let path: String
        let old: String
        let new: String

        var lines: [DiffLine] { DiffLine.diff(old, new) }
        var added: Int { lines.filter { $0.kind == .added }.count }
        var removed: Int { lines.filter { $0.kind == .removed }.count }
    }

    let verb: Verb
    /// The file, command, pattern or question, on one line.
    let subject: String
    /// The change this step made, for edits.
    let edit: Edit?

    /// The longest subject kept: a row shows one line, and a command can be a script.
    static let subjectLimit = 200
    /// The edits of a turn kept for the diff, the latest ones.
    static let editLimit = 20

    init(verb: Verb, subject: String, edit: Edit? = nil) {
        self.verb = verb
        let line = subject.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        self.subject = String(line.trimmingCharacters(in: .whitespaces).prefix(Self.subjectLimit))
        self.edit = edit
    }

    /// Claude Code's `tool_use` block, by tool name and input.
    static func claude(name: String, input: [String: Any]) -> [AgentActivity] {
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? ""
        switch name {
        case "Read", "NotebookRead": return [AgentActivity(verb: .read, subject: path)]
        case "Edit":
            return [AgentActivity(verb: .edit, subject: path, edit: Edit(path: path, old: input["old_string"] as? String ?? "",
                                                                        new: input["new_string"] as? String ?? ""))]
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]]) ?? []
            return edits.map {
                AgentActivity(verb: .edit, subject: path, edit: Edit(path: path, old: $0["old_string"] as? String ?? "", new: $0["new_string"] as? String ?? ""))
            }
        case "Write":
            return [AgentActivity(verb: .write, subject: path, edit: Edit(path: path, old: "", new: input["content"] as? String ?? ""))]
        case "NotebookEdit": return [AgentActivity(verb: .edit, subject: path)]
        case "Bash": return [AgentActivity(verb: .run, subject: input["command"] as? String ?? "")]
        case "Grep", "Glob": return [AgentActivity(verb: .search, subject: input["pattern"] as? String ?? "")]
        case "WebSearch": return [AgentActivity(verb: .search, subject: input["query"] as? String ?? "")]
        case "WebFetch": return [AgentActivity(verb: .read, subject: input["url"] as? String ?? "")]
        case "Task", "Agent": return [AgentActivity(verb: .delegate, subject: input["description"] as? String ?? "")]
        case "AskUserQuestion":
            let question = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return [AgentActivity(verb: .ask, subject: question ?? "")]
        default:
            // An MCP tool is named mcp__server__tool.
            let short = name.hasPrefix("mcp__") ? name.split(separator: "_", omittingEmptySubsequences: true).last.map(String.init) ?? name : name
            return [AgentActivity(verb: .tool(short), subject: "")]
        }
    }

    /// Codex's `function_call` (a JSON string of arguments) or `custom_tool_call` (raw input, for `apply_patch`).
    static func codex(name: String, arguments: String?, input: String?) -> [AgentActivity] {
        if name == "apply_patch" {
            let patch = input ?? (arguments.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])?["input"] as? String
            return patch.map(Self.patchEdits) ?? []
        }
        let object = arguments.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
        switch name {
        case "shell", "container.exec", "local_shell", "exec_command", "shell_command":
            let command = (object["command"] as? [String])?.joined(separator: " ") ?? object["command"] as? String ?? object["cmd"] as? String ?? ""
            // `bash -lc "<script>"` is how Codex runs most commands; the script is what was run.
            if let parts = object["command"] as? [String], parts.count == 3, ["bash", "zsh", "sh"].contains(parts[0]), parts[1].hasPrefix("-") {
                return [AgentActivity(verb: .run, subject: parts[2])]
            }
            return [AgentActivity(verb: .run, subject: command)]
        case "view_image": return [AgentActivity(verb: .read, subject: object["path"] as? String ?? "")]
        case "web_search": return [AgentActivity(verb: .search, subject: object["query"] as? String ?? "")]
        default: return [AgentActivity(verb: .tool(name), subject: "")]
        }
    }

    /// The files an `apply_patch` changes, each with its removed and added lines.
    static func patchEdits(_ patch: String) -> [AgentActivity] {
        var result: [AgentActivity] = []
        var path: String?, verb = Verb.edit, old: [String] = [], new: [String] = []
        func flush() {
            guard let path else { return }
            result.append(AgentActivity(verb: verb, subject: path, edit: Edit(path: path, old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))))
        }
        for line in patch.components(separatedBy: "\n") {
            for (marker, kind) in [("*** Update File: ", Verb.edit), ("*** Add File: ", .write), ("*** Delete File: ", .edit)] where line.hasPrefix(marker) {
                flush()
                (path, verb, old, new) = (String(line.dropFirst(marker.count)), kind, [], [])
            }
            guard path != nil, !line.hasPrefix("***"), !line.hasPrefix("@@") else { continue }
            if line.hasPrefix("+") { new.append(String(line.dropFirst())) }
            else if line.hasPrefix("-") { old.append(String(line.dropFirst())) }
            else if line.hasPrefix(" ") { old.append(String(line.dropFirst())); new.append(String(line.dropFirst())) }
        }
        flush()
        return result
    }
}

/// A line of a diff, in the order it reads.
struct DiffLine: Equatable {
    enum Kind: Equatable { case same, added, removed }
    let kind: Kind
    let text: String

    /// Past this many lines on either side the diff is only the old lines removed and the new ones added: finding the
    /// common lines costs their product.
    static let limit = 400

    /// The lines of `old` and `new`, with what they share kept in place and the rest as removed then added.
    static func diff(_ old: String, _ new: String) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        guard a.count <= limit, b.count <= limit else {
            return a.map { DiffLine(kind: .removed, text: $0) } + b.map { DiffLine(kind: .added, text: $0) }
        }
        // Longest common subsequence, from the ends.
        var length = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                length[i][j] = a[i] == b[j] ? length[i + 1][j + 1] + 1 : max(length[i + 1][j], length[i][j + 1])
            }
        }
        var result: [DiffLine] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                result.append(DiffLine(kind: .same, text: a[i])); i += 1; j += 1
            } else if j < b.count, i == a.count || length[i][j + 1] > length[i + 1][j] {
                result.append(DiffLine(kind: .added, text: b[j])); j += 1
            } else {
                result.append(DiffLine(kind: .removed, text: a[i])); i += 1
            }
        }
        // Removed lines read before the added ones that replace them.
        var ordered: [DiffLine] = [], added: [DiffLine] = []
        for line in result {
            switch line.kind {
            case .added: added.append(line)
            case .removed: ordered.append(line)
            case .same: ordered += added; added = []; ordered.append(line)
            }
        }
        return ordered + added
    }
}
