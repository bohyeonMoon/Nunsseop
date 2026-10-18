import Foundation

/// `~/.copilot/hooks/nunsseop.json`, a file of Nunsseop's own in the folder Copilot reads user hooks from
/// (https://docs.github.com/en/copilot/reference/hooks-configuration): `{"version": 1, "hooks": {<camelCase event>: [{"type": "command",
/// "bash": ..., "timeoutSec": ...}]}}`. Copilot's events carry no name of their own, so each hook says which it is.
///
/// - `sessionStart`, `userPromptSubmitted`, `agentStop` and `sessionEnd` are a session, a turn that began, a turn that ended and the end;
/// - `notification` (the CLI's own) says when it waits for the user (`permission_prompt`, `elicitation_dialog`) or sits idle
///   (`agent_idle`): the count reads the type, and the same three also show as a notice, with Copilot's own message;
/// - `permissionRequest` holds the approval until it is answered in the notch (see `PermissionDialect.copilot`).
///
/// Copilot reads an exit code of 2 from a command hook as a denial, so none of these ever ends with anything but 0.
enum CopilotHooks {
    /// Where Copilot reads user hooks from: `$COPILOT_HOME/hooks` when the app itself was started with it set, else `~/.copilot/hooks`.
    static var folder: URL {
        if NotifyIntegration.homeOverride == nil, let custom = ProcessInfo.processInfo.environment["COPILOT_HOME"], custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return NotifyIntegration.home.appendingPathComponent(".copilot", isDirectory: true)
    }

    static var fileURL: URL { folder.appendingPathComponent("hooks/nunsseop.json") }

    static let noticeTypes = "permission_prompt|elicitation_dialog|agent_idle"

    static func isOurs(text: String) -> Bool {
        guard let hooks = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { events in
            ((events as? [Any]) ?? []).contains { HookCommands.isOurs(command: ($0 as? [String: Any])?["bash"] as? String ?? "", noticeTitles: ["GitHub Copilot"]) }
        }
    }

    /// The notice for the types above, whose message Copilot gives in `message`.
    static var noticeCommand: String {
        "in=$(cat); case $(printf %s \"$in\" | plutil -extract notification_type raw -o - - 2>/dev/null) in \(noticeTypes)) printf %s \"$in\" | "
            + NotifyServer.hookCommand(title: "GitHub Copilot") + " ;; esac; true"
    }

    static func source(permissions: Bool) -> String {
        func agent(_ event: String, type: String = "") -> String {
            NotifyServer.toolHookCommand(for: .copilot, session: "sessionId", event: event, type: type)
        }
        func entry(_ command: String, timeout: Int = HookCommands.eventTimeout) -> [String: Any] {
            ["type": "command", "bash": command, "timeoutSec": timeout]
        }
        var hooks: [String: [[String: Any]]] = [
            "sessionStart": [entry(agent("SessionStart"))],
            "userPromptSubmitted": [entry(agent("UserPromptSubmit"))],
            "agentStop": [entry(agent("Stop"))],
            "sessionEnd": [entry(agent("SessionEnd"))],
            "notification": [entry(agent("Notification", type: "$(k notification_type)")), entry(noticeCommand)],
        ]
        if permissions {
            hooks["permissionRequest"] = [entry(NotifyServer.permissionHookCommand(port: NotifyServer.port, agent: .copilot),
                                                timeout: HookCommands.permissionTimeout)]
        }
        let file: [String: Any] = ["version": 1, "hooks": hooks]
        let data = (try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
