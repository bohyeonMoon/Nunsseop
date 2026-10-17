import Foundation

/// The tools besides Claude Code, Codex and OpenCode whose permission hooks the notch answers. Each sends its own input and reads its
/// own answer from the hook's output; the hook (see `NotifyServer.permissionHookCommand`) says which one it is in `X-Agent`, and the server
/// does the translating at both ends, so the one hook shell command serves them all:
///
/// - the input becomes a Claude Code `PermissionRequest` (`normalized`), from which the card is built as for any tool: a command, a file
///   path and what goes into it, or the tool's own name and its whole input. Whatever the tool sends that is not understood is listed,
///   never dropped, so what the card shows is all of what the call is;
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
        var input = Self.object(json["toolInput"] ?? json["tool_input"] ?? json["toolArgs"])
        // Whatever else the request carries is part of the call, and is listed after the arguments.
        let envelope: Set<String> = [key, "sessionId", "session_id", "timestamp", "cwd", "hook_event_name", "toolInput", "tool_input", "toolArgs"]
        for (field, value) in json where !envelope.contains(field) && input[field] == nil { input[field] = value }
        let tool = name.lowercased() == "bash" && (input["command"] as? String)?.isEmpty == false ? "Bash" : name
        return (tool, input, json["cwd"] as? String)
    }

    // MARK: Antigravity

    private func antigravityCall(_ json: [String: Any]) -> (tool: String, input: [String: Any], cwd: String?)? {
        guard let call = json["toolCall"] as? [String: Any], let name = call["name"] as? String, Self.antigravityTools.contains(name) else { return nil }
        var args = call["args"] as? [String: Any] ?? [:]
        let tool: String
        switch name {
        case "run_command":
            tool = "Bash"
            Self.rename(&args, "CommandLine", to: "command")
        case "write_to_file":
            tool = "Write"
            Self.rename(&args, "TargetFile", to: "file_path")
            Self.rename(&args, "CodeContent", to: "content")
        case "replace_file_content":
            tool = "Edit"
            Self.rename(&args, "TargetFile", to: "file_path")
            Self.rename(&args, "TargetContent", to: "old_string")
            Self.rename(&args, "ReplacementContent", to: "new_string")
        default:
            tool = "Edit"
            Self.rename(&args, "TargetFile", to: "file_path")
        }
        return (tool, args, args["Cwd"] as? String ?? (json["workspacePaths"] as? [Any])?.first as? String)
    }

    // MARK: Cursor

    private func cursorCall(_ json: [String: Any]) -> (tool: String, input: [String: Any], cwd: String?)? {
        let roots = (json["workspace_roots"] as? [Any])?.first as? String
        switch json["hook_event_name"] as? String {
        case "beforeShellExecution":
            guard let command = json["command"] as? String, !command.isEmpty else { return nil }
            var input: [String: Any] = ["command": command]
            input["sandbox"] = json["sandbox"]
            return ("Bash", input, json["cwd"] as? String ?? roots)
        case "beforeMCPExecution":
            guard let tool = json["tool_name"] as? String, !tool.isEmpty else { return nil }
            var input = Self.object(json["tool_input"])
            // Where the call goes is part of it.
            for (field, name) in [("mcp_server_url", "mcp_server_url"), ("url", "mcp_server_url"), ("command", "mcp_server_command")] {
                if let value = json[field], input[name] == nil { input[name] = value }
            }
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

    /// Renames `key` unless `name` is taken already, so nothing the tool sent is overwritten.
    private static func rename(_ object: inout [String: Any], _ key: String, to name: String) {
        guard let value = object[key], object[name] == nil else { return }
        object[key] = nil
        object[name] = value
    }
}
