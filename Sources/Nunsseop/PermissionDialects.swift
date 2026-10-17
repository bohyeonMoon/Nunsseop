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

    /// The request as Claude Code's `PermissionRequest` hook would have sent it; nil when the call is none that is put to the user, or says
    /// nothing of what it is.
    func normalized(_ json: [String: Any]) -> [String: Any]? {
        let call: (tool: String, input: [String: Any], cwd: String?)?
        switch self {
        case .copilot: call = copilotCall(json)
        case .agy: call = antigravityCall(json)
        case .cursor: call = cursorCall(json)
        }
        guard let call else { return nil }
        var request: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": call.tool, "tool_input": call.input]
        request["cwd"] = call.cwd
        return request
    }

    // MARK: Copilot

    private func copilotCall(_ json: [String: Any]) -> (tool: String, input: [String: Any], cwd: String?)? {
        let nameKeys = ["toolName", "tool_name", "kind"]
        guard let key = nameKeys.first(where: { (json[$0] as? String)?.isEmpty == false }), let name = json[key] as? String else { return nil }
        // One name, one place for the arguments.
        if let camel = json["toolName"], let snake = json["tool_name"], (camel as? String) != (snake as? String) { return nil }
        let places = ["toolInput", "tool_input", "toolArgs"].filter { json[$0] != nil }
        guard places.count <= 1 else { return nil }
        var input = Self.object(places.first.flatMap { json[$0] })
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
        guard let call = json["toolCall"] as? [String: Any], let name = call["name"] as? String, Self.antigravityTools.contains(name) else { return nil }
        var args = call["args"] as? [String: Any] ?? [:]
        let tool: String
        let renames: [(String, String)]
        switch name {
        case "run_command": (tool, renames) = ("Bash", [("CommandLine", "command")])
        case "write_to_file": (tool, renames) = ("Write", [("TargetFile", "file_path"), ("CodeContent", "content")])
        case "replace_file_content":
            (tool, renames) = ("Edit", [("TargetFile", "file_path"), ("TargetContent", "old_string"), ("ReplacementContent", "new_string")])
        default: (tool, renames) = ("Edit", [("TargetFile", "file_path")])
        }
        // Antigravity's tools have none of Claude Code's field names: one in the arguments is not what runs.
        guard args.keys.allSatisfy({ !Self.meaningful.contains($0) }) else { return nil }
        for (key, claudeName) in renames { guard Self.rename(&args, key, to: claudeName) else { return nil } }
        return (tool, args, args["Cwd"] as? String ?? (json["workspacePaths"] as? [Any])?.first as? String)
    }

    // MARK: Cursor

    private func cursorCall(_ json: [String: Any]) -> (tool: String, input: [String: Any], cwd: String?)? {
        let roots = (json["workspace_roots"] as? [Any])?.first as? String
        switch json["hook_event_name"] as? String {
        case "beforeShellExecution":
            guard let command = json["command"] as? String, !command.isEmpty else { return nil }
            // The docs don't say what `sandbox` means for this hook; a false (or anything but a true) may be a command that runs outside
            // the sandbox, which an allow may not govern. Cursor asks for itself.
            guard json["sandbox"] == nil || (json["sandbox"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true else { return nil }
            var input: [String: Any] = ["command": command]
            input["sandbox"] = json["sandbox"]
            return ("Bash", input, json["cwd"] as? String ?? roots)
        case "beforeMCPExecution":
            guard let tool = json["tool_name"] as? String, !tool.isEmpty else { return nil }
            var input = Self.object(json["tool_input"])
            // Where the call goes is part of it.
            // A name the input has already, or two fields for one name, leave it open which one is where the call goes.
            var added: [String: Any] = [:]
            for (field, name) in [("mcp_server_url", "mcp_server_url"), ("url", "mcp_server_url"), ("command", "mcp_server_command")] {
                guard let value = json[field] else { continue }
                guard input[name] == nil, added[name] == nil else { return nil }
                added[name] = value
            }
            input.merge(added) { $1 }
            let server = (json["mcp_server_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (server.map { "mcp__\($0)__\(tool)" } ?? tool, input, json["cwd"] as? String ?? roots)
        default:
            return nil
        }
    }

    // MARK: Shared

    /// A tool's arguments as an object: an object as it is, a string that holds one parsed, any other string or value under `input`.
    private static func object(_ value: Any?) -> [String: Any] {
        switch value {
        case nil, is NSNull: return [:]
        case let object as [String: Any]: return object
        case let text as String:
            if let data = text.data(using: .utf8), let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return parsed }
            return text.isEmpty ? [:] : ["input": text]
        default: return ["input": value as Any]
        }
    }

    /// The names the card reads as the command, the file or what goes into it (see `PermissionPrompt.describe`).
    private static let meaningful: Set<String> = ["command", "file_path", "content", "old_string", "new_string", "edits", "notebook_path", "new_source",
                                                  "url", "query", "description", "run_in_background", "dangerouslyDisableSandbox"]

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
