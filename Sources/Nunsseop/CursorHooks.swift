import Foundation

/// Hooks of Nunsseop's in `~/.cursor/hooks.json` (https://cursor.com/docs/hooks): `{"version": 1, "hooks": {<event>: [{"command": ...,
/// "timeout": ...}]}}`, a file that other tools add to as well, so Nunsseop's entries are told by what they run and every other entry
/// stays where it is.
///
/// - `sessionStart`, `beforeSubmitPrompt`, `stop` and `sessionEnd` are a session, a turn that began, a turn that ended (a `completed`
///   one also shows as a notice; an `aborted` or failed one only ends the work) and the end;
/// - `beforeShellExecution` and `beforeMCPExecution` hold the approval until it is answered in the notch (see `PermissionDialect.cursor`).
///
/// A conversation is the session. Cursor's agent has no terminal and its hooks run in a process that hosts several conversations, so
/// no process is named: the row goes to the Cursor app, which is what `__CFBundleIdentifier` says when it runs the hook.
enum CursorHooks {
    typealias Table = [(event: String, entry: [String: Any])]

    /// Cursor's bundle identifier, for a hook that macOS names no app for.
    static let bundleID = "com.todesktop.230313mzl4w4u92"

    static func isOurs(entry: Any) -> Bool {
        HookCommands.isOurs(command: (entry as? [String: Any])?["command"] as? String ?? "", noticeTitles: ["Cursor"])
    }

    static func table(permissions: Bool) -> Table {
        func entry(_ command: String, timeout: Int = HookCommands.eventTimeout) -> [String: Any] { ["command": command, "timeout": timeout] }
        func agent(_ event: String, after: String? = nil) -> String {
            NotifyServer.toolHookCommand(for: .cursor, session: "conversation_id", event: event, app: bundleID, pid: false, after: after)
        }
        let completed = "[ \"$(k status)\" = completed ]"
        // A turn Cursor ended without finishing it (stopped, or failed) is no finished hand.
        let stop = agent("$([ \"$(k status)\" = completed ] && echo Stop || echo Interrupt)")
        var table: Table = [
            ("sessionStart", entry(agent("SessionStart"))),
            // The hook that runs before a prompt is sent answers in JSON; this one has nothing to add.
            ("beforeSubmitPrompt", entry(agent("UserPromptSubmit", after: "printf '{\"continue\":true}'"))),
            ("stop", entry(stop)),
            ("stop", entry(NotifyServer.noticeCommand(title: "Cursor", message: "Finished", only: completed, app: bundleID))),
            ("sessionEnd", entry(agent("SessionEnd"))),
        ]
        if permissions {
            let command = NotifyServer.permissionHookCommand(port: NotifyServer.port, agent: .cursor)
            table.append(("beforeShellExecution", entry(command, timeout: HookCommands.permissionTimeout)))
            table.append(("beforeMCPExecution", entry(command, timeout: HookCommands.permissionTimeout)))
        }
        return table
    }

    private static func events(in settings: [String: Any]) -> [String: Any] { settings["hooks"] as? [String: Any] ?? [:] }

    /// Nunsseop's entries as they stand in the settings, by event.
    private static func held(in settings: [String: Any]) -> [String: [[String: Any]]] {
        events(in: settings).compactMapValues { value in
            let ours = ((value as? [Any]) ?? []).filter(isOurs(entry:)).compactMap { $0 as? [String: Any] }
            return ours.isEmpty ? nil : ours
        }
    }

    static func holdsAny(in settings: [String: Any]) -> Bool { !held(in: settings).isEmpty }

    /// The settings with exactly the entries of `table` as Nunsseop's, the others where they were; nil when that is so already.
    static func updating(_ table: Table, in settings: [String: Any]) throws -> [String: Any]? {
        var wanted: [String: [[String: Any]]] = [:]
        for (event, entry) in table { wanted[event, default: []].append(entry) }
        let current = held(in: settings)
        if current.count == wanted.count, wanted.allSatisfy({ event, entries in
            current[event].map { NSArray(array: $0).isEqual(to: entries) } ?? false
        }) { return nil }
        var updated = removing(from: settings)
        guard var hooks = (updated["hooks"] ?? [String: Any]()) as? [String: Any] else { throw NotifyIntegration.IntegrationError.unreadableConfig }
        for (event, entries) in wanted {
            guard let others = (hooks[event] ?? [Any]()) as? [Any] else { throw NotifyIntegration.IntegrationError.unreadableConfig }
            hooks[event] = others + entries
        }
        updated["hooks"] = hooks
        if updated["version"] == nil { updated["version"] = 1 }
        return updated
    }

    /// The settings without Nunsseop's entries. The others, and whatever isn't an object, stay; an event is dropped only when nothing is
    /// left under it.
    static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any], holdsAny(in: settings) else { return settings }
        for (event, value) in hooks {
            guard let entries = value as? [Any], entries.contains(where: isOurs(entry:)) else { continue }
            let kept = entries.filter { !isOurs(entry: $0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var updated = settings
        updated["hooks"] = hooks.isEmpty ? nil : hooks
        return updated
    }
}
