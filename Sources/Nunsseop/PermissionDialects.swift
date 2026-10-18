import Foundation

/// The tools besides Claude Code, Codex and OpenCode whose permission hooks the notch answers. Each sends its own input and reads its
/// own answer from the hook's output; the hook (see `NotifyServer.permissionHookCommand`) says which one it is in `X-Agent`, and the server
/// does the translating at both ends, so the one hook shell command serves them all:
///
/// - the input becomes a Claude Code `PermissionRequest` (`normalized`), from which the card is built as for any tool: a command, a file
///   path and what goes into it, or the tool's own name and its whole input. Whatever the tool sends that is not understood is listed,
///   never dropped, so what the card shows is all of what the call is. Where two values could be the one that runs (a field the
///   translation would write that the input has already, a field of the envelope that the arguments also have), there is no card at
///   all: nil, the hook prints nothing and the tool asks in its own prompt. So it is for the calls that the tool lets only a denial
///   govern (Copilot's sandbox bypass) or whose sandbox is off or unknown (Cursor's);
/// - the user's answer becomes what the tool reads back (`allowed`, `denied`).
///
/// Every card of these says whose it is and offers "Answer in terminal" in place of "Always allow": the tool shows its own prompt once
/// the hook says nothing.
enum PermissionDialect: String {
    /// GitHub Copilot CLI's `permissionRequest` hook (https://docs.github.com/en/copilot/reference/hooks-configuration): camelCase input,
    /// of which the docs name `toolName` and, inside `toolInput`, `requestSandboxBypass`; the rest of its shape isn't documented, so it is
    /// read defensively. Answers `{"behavior": "allow" | "deny", "message"}`; empty output falls through to Copilot's own prompt.
    case copilot
    /// Antigravity CLI's `PreToolUse` hook (https://antigravity.google/docs/hooks): `toolCall` with `name` and `args`. Answers
    /// `{"decision": ..., "reason"}`.
    case agy
    /// Cursor's `beforeShellExecution` and `beforeMCPExecution` hooks (https://cursor.com/docs/hooks). Answers
    /// `{"permission": "allow" | "deny", "user_message", "agent_message"}`.
    case cursor

    /// The tool a request's `X-Agent` names; nil for none of these (Claude Code's hook sends no such header).
    init?(agent: String?) {
        guard let agent else { return nil }
        self.init(rawValue: agent)
    }

    /// What the card names before its title.
    var tag: String {
        switch self {
        case .copilot: "Copilot"
        case .agy: "Antigravity"
        case .cursor: "Cursor"
        }
    }

    /// The answer when the user allows the call. Antigravity's `auto_approve` is the one that approves "where the default policy would
    /// otherwise prompt, while honoring explicit user-configured rules"; its `allow` only defers to the next hook or the default policy,
    /// which would put the question to the user a second time.
    var allowed: [String: Any] {
        switch self {
        case .copilot: ["behavior": "allow"]
        case .agy: ["decision": "auto_approve", "reason": PermissionWire.allowMessage]
        case .cursor: ["permission": "allow"]
        }
    }

    var denied: [String: Any] {
        switch self {
        case .copilot: ["behavior": "deny", "message": PermissionWire.denyMessage]
        case .agy: ["decision": "deny", "reason": PermissionWire.denyMessage]
        case .cursor: ["permission": "deny", "user_message": PermissionWire.denyMessage, "agent_message": PermissionWire.denyMessage]
        }
    }

    /// The tools of Antigravity that are put to the user: a command and the three that write a file. The rest (reading, searching,
    /// listing) isn't, and the hook doesn't even start the dance with the server for them.
    static let antigravityTools = ["run_command", "write_to_file", "replace_file_content", "multi_replace_file_content"]

    /// The arguments each of them has, by the docs, and the ones a call cannot do without (and that are text). A call with any other
    /// argument has a field the card can't be sure of, and gets none: Antigravity asks for itself.
    private static let antigravityArguments: [String: (all: Set<String>, text: [String])] = [
        "run_command": (["CommandLine", "Cwd", "WaitMsBeforeAsync", "RunPersistent", "RequestedTerminalID"], ["CommandLine"]),
        "write_to_file": (["TargetFile", "Overwrite", "CodeContent", "Description", "IsArtifact", "ArtifactMetadata"], ["TargetFile", "CodeContent"]),
        "replace_file_content": (["TargetFile", "Instruction", "Description", "AllowMultiple", "TargetContent", "ReplacementContent", "StartLine",
                                  "EndLine", "TargetLintErrorIds"], ["TargetFile", "TargetContent", "ReplacementContent"]),
        "multi_replace_file_content": (["TargetFile", "Instruction", "Description", "ReplacementChunks", "TargetLintErrorIds", "ArtifactMetadata"], ["TargetFile"]),
    ]

    /// The fields of every Cursor hook that say who and where, not what: the card needs none of them. Any other field of a call is part of
    /// it, and listed.
    private static let cursorEnvelope: Set<String> = ["conversation_id", "generation_id", "model", "model_id", "model_params", "hook_event_name",
                                                      "cursor_version", "workspace_roots", "user_email", "transcript_path"]

    /// The request as Claude Code's `PermissionRequest` hook would have sent it; nil when the call is none that is put to the user, says
    /// nothing of what it is, or leaves open what it is.
    func normalized(_ json: [String: Any]) -> [String: Any]? {
        let call: (tool: String, input: [String: Any], cwd: String?)?
        switch self {
        case .copilot: call = copilotCall(json)
        case .agy: call = antigravityCall(json)
        case .cursor: call = cursorCall(json)
        }
        guard let call, !Self.isAmbiguous(tool: call.tool, input: call.input) else { return nil }
        var request: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": call.tool, "tool_input": call.input]
        request["cwd"] = call.cwd
        return request
    }

    // MARK: Copilot

    private func copilotCall(_ json: [String: Any]) -> (tool: String, input: [String: Any], cwd: String?)? {
        let nameKeys = ["toolName", "tool_name", "kind"]
        guard let key = nameKeys.first(where: { (json[$0] as? String)?.isEmpty == false }), let name = json[key] as? String else { return nil }
        // One name, one place for the arguments; and no other spelling of either.
        if let camel = json["toolName"], let snake = json["tool_name"], (camel as? String) != (snake as? String) { return nil }
        let places = ["toolInput", "tool_input", "toolArgs"]
        guard Self.hasNoRivalContainer(json, allowed: ["toolName", "tool_name"] + places),
              places.filter({ json[$0] != nil }).count <= 1 else { return nil }
        guard var input = Self.arguments(places.first { json[$0] != nil }.flatMap { json[$0] }) else { return nil }
        // Docs: a sandbox bypass can't be allowed in advance, only denied; Copilot asks for it itself.
        guard input["requestSandboxBypass"] == nil, json["requestSandboxBypass"] == nil else { return nil }
        // Whatever else the request carries is part of the call, and is listed after the arguments, as long as it is not the same field as
        // one of them, nor one that the card would read as the command or the file of the call.
        let envelope: Set<String> = [key, "sessionId", "session_id", "timestamp", "cwd", "hook_event_name", "toolInput", "tool_input", "toolArgs"]
        for (field, value) in json where !envelope.contains(field) {
            guard input[field] == nil, !Self.meaningful.contains(field) else { return nil }
            input[field] = value
        }
        let tool = name.lowercased() == "bash" && (input["command"] as? String)?.isEmpty == false ? "Bash" : name
        return (tool, input, json["cwd"] as? String)
    }

    // MARK: Antigravity

    private func antigravityCall(_ json: [String: Any]) -> (tool: String, input: [String: Any], cwd: String?)? {
        guard let call = json["toolCall"] as? [String: Any], let name = call["name"] as? String, let known = Self.antigravityArguments[name],
              call.keys.allSatisfy({ ["name", "args", "id", "callId", "toolCallId", "toolUseId"].contains($0) }) else { return nil }
        guard var args = call["args"] as? [String: Any], args.keys.allSatisfy(known.all.contains),
              name != "multi_replace_file_content" || args["ReplacementChunks"] is [Any],
              known.text.allSatisfy({ (args[$0] as? String)?.isEmpty == false || (name == "write_to_file" && $0 == "CodeContent" && args[$0] is String) }) else { return nil }
        // Nor does the request hold another toolCall or arguments beside the one read.
        guard Self.hasNoRivalContainer(json, allowed: ["toolCall"]) else { return nil }
        // The folder it runs in is part of the call, and its arguments' own.
        let cwd = args["Cwd"] as? String ?? (json["workspacePaths"] as? [Any])?.first as? String
        let tool: String
        let renames: [(String, String)]
        switch name {
        case "run_command": (tool, renames) = ("Bash", [("CommandLine", "command")])
        case "write_to_file": (tool, renames) = ("Write", [("TargetFile", "file_path"), ("CodeContent", "content")])
        case "replace_file_content":
            (tool, renames) = ("Edit", [("TargetFile", "file_path"), ("TargetContent", "old_string"), ("ReplacementContent", "new_string")])
        default: (tool, renames) = ("Edit", [("TargetFile", "file_path")])
        }
        // None of these tools has a field of Claude Code's names, and every field it has is listed with its own name.
        guard args.keys.allSatisfy({ !Self.meaningful.contains($0) }) else { return nil }
        for (key, claudeName) in renames { guard Self.rename(&args, key, to: claudeName) else { return nil } }
        return (tool, args, cwd)
    }

    // MARK: Cursor

    private func cursorCall(_ json: [String: Any]) -> (tool: String, input: [String: Any], cwd: String?)? {
        let roots = (json["workspace_roots"] as? [Any])?.first as? String
        guard Self.hasNoRivalContainer(json, allowed: ["tool_name", "tool_input"]) else { return nil }
        // The fields of the hook that are the call's own are listed, whatever they are, and none may be read as a command or a file.
        func rest(besides known: Set<String>) -> [String: Any]? {
            var extra: [String: Any] = [:]
            for (field, value) in json where !Self.cursorEnvelope.contains(field) && !known.contains(field) {
                guard !Self.meaningful.contains(field) else { return nil }
                extra[field] = value
            }
            return extra
        }
        switch json["hook_event_name"] as? String {
        case "beforeShellExecution":
            guard let command = json["command"] as? String, !command.isEmpty, let extra = rest(besides: ["command", "cwd", "sandbox"]) else { return nil }
            // The docs don't say what `sandbox` means for this hook; a false (or anything but a true) may be a command that runs outside
            // the sandbox, which an allow may not govern. Cursor asks for itself.
            guard json["sandbox"] == nil || (json["sandbox"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true else { return nil }
            // Where the command runs is part of it, and shown whole, not by the name of its last folder.
            var input = extra.merging(["command": command]) { $1 }
            input["sandbox"] = json["sandbox"]
            input["cwd"] = json["cwd"]
            return ("Bash", input, json["cwd"] as? String ?? roots)
        case "beforeMCPExecution":
            guard let tool = json["tool_name"] as? String, !tool.isEmpty, var input = Self.arguments(json["tool_input"]),
                  let extra = rest(besides: ["tool_name", "tool_input", "mcp_server_name", "url", "mcp_server_url", "command", "cwd"]) else { return nil }
            // Where the call goes is part of it. A name the input has already, or two fields for one name, leave it open which one is where
            // the call goes.
            var added: [String: Any] = [:]
            for (field, name) in [("mcp_server_url", "mcp_server_url"), ("url", "mcp_server_url"), ("command", "mcp_server_command"), ("cwd", "cwd")] {
                guard let value = json[field] else { continue }
                guard input[name] == nil, added[name] == nil else { return nil }
                added[name] = value
            }
            for (field, value) in extra {
                guard input[field] == nil, added[field] == nil else { return nil }
                added[field] = value
            }
            input.merge(added) { $1 }
            let server = (json["mcp_server_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (server.map { "mcp__\($0)__\(tool)" } ?? tool, input, json["cwd"] as? String ?? roots)
        default:
            return nil
        }
    }

    // MARK: Shared

    /// A tool's arguments as an object: an object as it is, a string that holds one as that object, nothing as no arguments. nil for
    /// anything else: a string that is no JSON object (or has a key twice, which parsers read differently), an array, a number.
    private static func arguments(_ value: Any?) -> [String: Any]? {
        switch value {
        case nil, is NSNull: return [:]
        case let object as [String: Any]: return object
        case let text as String: return text.isEmpty ? [:] : StrictJSON.object(from: text)
        default: return nil
        }
    }

    /// The names the card reads as the command, the file or what goes into it (see `PermissionPrompt.describe`).
    private static let meaningful: Set<String> = ["command", "file_path", "content", "old_string", "new_string", "edits", "notebook_path", "new_source",
                                                  "url", "query", "description", "run_in_background", "dangerouslyDisableSandbox"]

    /// A name without its case, underscores and hyphens: `CommandLine`, `command_line` and `command-line` are one.
    private static func spelled(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Names that stand for one kind of thing in a call, by spelling: what runs, the file it is about, what goes into it, what it replaces and what
    /// it is replaced by. A call that has two names of one kind has two candidates for what runs.
    private static let kinds: [Set<String>] = [
        ["command", "cmd", "commandline", "commandtext", "fullcommand", "fullcommandtext", "shellcommand", "commandstring", "script", "args", "arguments", "argv", "exec",
         "run", "shell"],
        ["filepath", "path", "file", "filename", "targetfile", "notebookpath", "uri", "target"],
        ["content", "contents", "text", "codecontent", "newsource", "body", "data"],
        ["oldstring", "oldstr", "oldtext", "targetcontent", "search", "find"],
        ["newstring", "newstr", "newtext", "replacementcontent", "replacement", "replace"],
    ]

    /// Whether the call has two names of one kind, or, for a card that shows a command or a file as its headline, a name of any kind
    /// besides the one it reads (`cmd`, `commandLine`, `Command` beside `command`); which one the tool runs is not for the card to guess.
    /// A tool with no headline lists every field by its name, and a single `path` among them is just that.
    private static func isAmbiguous(tool: String, input: [String: Any]) -> Bool {
        let spellings = input.keys.filter { !meaningful.contains($0) }.map(spelled)
        if ["Bash", "Edit", "Write"].contains(tool), spellings.contains(where: { name in kinds.contains { $0.contains(name) } }) { return true }
        return kinds.contains { kind in input.keys.filter { kind.contains(spelled($0)) }.count > 1 }
    }

    /// The names under which a request holds the call or its arguments.
    private static let containers: Set<String> = ["toolname", "toolinput", "toolargs", "toolcall", "args", "arguments", "input", "params", "parameters", "toolparams"]

    /// Whether the request has no field that spells the name of the call or its arguments differently from the ones read (`ToolArgs`,
    /// `arguments`): the tool might read that one.
    private static func hasNoRivalContainer(_ json: [String: Any], allowed: [String]) -> Bool {
        json.keys.allSatisfy { allowed.contains($0) || !containers.contains(spelled($0)) }
    }

    /// Renames `key` (when there is one); false when `name` is there already, which would hide one of the two.
    private static func rename(_ object: inout [String: Any], _ key: String, to name: String) -> Bool {
        guard object[name] == nil else { return false }
        if let value = object[key] {
            object[key] = nil
            object[name] = value
        }
        return true
    }
}
