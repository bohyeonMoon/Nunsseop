import Foundation

/// A hook of Nunsseop's in `~/.gemini/config/hooks.json` (https://antigravity.google/docs/hooks), which Antigravity's app, CLI and IDE
/// read and other tools add to as well. The file maps a name of the hook's author's choosing to its events; Nunsseop's is one named
/// `nunsseop`, so connecting sets that one key and disconnecting removes it, and every other tool's hooks stay as they were.
///
/// - `SessionStart`, `PreInvocation` (a model call is under way) and `Stop` with `fullyIdle` set (the agent has nothing left to do) are
///   a session, working and a turn that ended; a finished turn also shows as a notice;
/// - `PreToolUse` for a command or a file change holds the approval until it is answered in the notch (see `PermissionDialect.agy`).
///   Nothing is printed when Nunsseop isn't running, so Antigravity decides as it would without the hook.
///
/// There is no event for the end of a session: the hook's parent process (`$PPID`) is looked at instead.
enum AntigravityHooks {
    static let name = "nunsseop"

    static func isOurs(_ group: Any?) -> Bool {
        guard let events = group as? [String: Any] else { return false }
        return events.values.contains { handlers in
            ((handlers as? [Any]) ?? []).contains { handler in
                let handler = handler as? [String: Any] ?? [:]
                return commands(in: handler).contains { HookCommands.isOurs(command: $0, noticeTitles: ["Antigravity"]) }
            }
        }
    }

    /// The commands of a handler, or of the handlers a matcher group holds.
    private static func commands(in handler: [String: Any]) -> [String] {
        [handler["command"] as? String].compactMap { $0 }
            + ((handler["hooks"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["command"] as? String }
    }

    static func group(permissions: Bool) -> [String: Any] {
        func handler(_ command: String, timeout: Int = HookCommands.eventTimeout) -> [String: Any] {
            ["type": "command", "command": command, "timeout": timeout]
        }
        func agent(_ event: String, only: String? = nil) -> String {
            NotifyServer.toolHookCommand(for: .agy, session: "conversationId", event: event, only: only)
        }
        let idle = "[ \"$(k fullyIdle)\" = true ]"
        var events: [String: Any] = [
            "SessionStart": [handler(agent("SessionStart"))],
            "PreInvocation": [handler(agent("UserPromptSubmit"))],
            "Stop": [handler(agent("Stop", only: idle)),
                     handler(NotifyServer.noticeCommand(title: "Antigravity", message: "Finished", only: idle))],
        ]
        if permissions {
            events["PreToolUse"] = [["matcher": PermissionDialect.antigravityTools.joined(separator: "|"),
                                     "hooks": [handler(NotifyServer.permissionHookCommand(port: NotifyServer.port, agent: .agy),
                                                       timeout: HookCommands.permissionTimeout)]]]
        }
        return events
    }

    static func isInstalled(in settings: [String: Any]) -> Bool { isOurs(settings[name]) }

    /// The settings with Nunsseop's group set; nil when it already is. A group of that name that isn't Nunsseop's is another tool's, and
    /// is never replaced.
    static func updating(_ settings: [String: Any], permissions: Bool) throws -> [String: Any]? {
        if let existing = settings[name], !isOurs(existing) { throw NotifyIntegration.IntegrationError.unreadableConfig }
        let wanted = group(permissions: permissions)
        if let existing = settings[name] as? [String: Any], NSDictionary(dictionary: existing).isEqual(to: wanted) { return nil }
        var updated = settings
        updated[name] = wanted
        return updated
    }

    static func removing(from settings: [String: Any]) -> [String: Any] {
        guard isOurs(settings[name]) else { return settings }
        var kept = settings
        kept[name] = nil
        return kept
    }
}
