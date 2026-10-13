import Foundation

/// Command-line tools whose notifications Nunsseop can show, each wired up by editing that tool's own config.
/// Every change keeps the tool's other settings, and the JSON and TOML files are backed up first. omp, omo and pi are
/// connected by a file of Nunsseop's in their extensions folder (see `PiExtension`).
enum NotifyIntegration: String, CaseIterable, Identifiable {
    case claudeCode, codex, gemini, openCode, omp, omo, pi

    enum IntegrationError: Error { case unreadableConfig, unreadableHooks }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .openCode: "OpenCode"
        case .omp, .omo, .pi: piAgent?.displayName ?? rawValue
        }
    }

    /// The tool of the pi family this connects; nil for the others.
    var piAgent: AgentKind? {
        switch self {
        case .omp: .omp
        case .omo: .omo
        case .pi: .pi
        case .claudeCode, .codex, .gemini, .openCode: nil
        }
    }

    /// Where tests point the tools' config folders (and, through `NotifyServer.tokenURL`, Application Support).
    @TaskLocal static var homeOverride: URL?

    /// Where tests set whether Claude Code's permission prompts are answered in the notch; otherwise the setting decides.
    @TaskLocal static var permissionPromptsOverride: Bool?

    /// Read from the defaults, since the hooks are worked out off the main actor.
    static var answersPermissions: Bool {
        permissionPromptsOverride ?? AppSettings.load("permissionPrompts", default: true)
    }

    static var home: URL { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser }

    /// The file Nunsseop changes or adds.
    var configURL: URL {
        switch self {
        case .claudeCode: Self.home.appendingPathComponent(".claude/settings.json")
        case .codex: Self.home.appendingPathComponent(".codex/config.toml")
        case .gemini: Self.home.appendingPathComponent(".gemini/settings.json")
        case .openCode: Self.home.appendingPathComponent(".config/opencode/plugins/nunsseop.js")
        case .omp, .omo, .pi: Self.home.appendingPathComponent(".\(rawValue)/agent/extensions/nunsseop.ts")
        }
    }

    /// Shown only when the tool has been used on this Mac.
    var isPresent: Bool {
        let folder: URL
        switch self {
        case .openCode: folder = Self.home.appendingPathComponent(".config/opencode")
        case .omp, .omo, .pi: folder = Self.home.appendingPathComponent(".\(rawValue)/agent")
        case .claudeCode, .codex, .gemini: folder = configURL.deletingLastPathComponent()
        }
        return FileManager.default.fileExists(atPath: folder.path)
    }

    /// The tools among `present` whose permission prompts can be answered in the notch; each is explained under the setting.
    static func askingForPermission(present: Set<NotifyIntegration>) -> Set<NotifyIntegration> {
        present.intersection([.claudeCode, .codex, .openCode])
    }

    /// The tools that report their sessions for the agents count, once connected.
    static let reportingSessions: [NotifyIntegration] = [.claudeCode, .codex, .openCode, .omp, .omo, .pi]

    /// Where Codex reads lifecycle hooks, next to its config. Its notices stay with the notify command in `configURL`.
    var hooksURL: URL { configURL.deletingLastPathComponent().appendingPathComponent("hooks.json") }

    /// The hooks Nunsseop keeps in a JSON tool's settings. Claude Code and Codex also report their sessions for the
    /// agents count and ask for permission prompts; Gemini CLI's event names aren't known well enough for that.
    var hooks: JSONHook.Table {
        switch self {
        case .claudeCode:
            let agent = NotifyServer.agentHookCommand
            return [("Notification", NotifyServer.hookCommand(title: name))]
                + ["Notification", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd", "SessionStart"].map { ($0, agent) }
                + (Self.answersPermissions ? [("PermissionRequest", NotifyServer.permissionHookCommand),
                                              ("PreToolUse", NotifyServer.permissionHookCommand)] : [])
        case .codex:
            let agent = NotifyServer.agentHookCommand(for: .codex)
            return ["UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"].map { ($0, agent) }
                // After the agent hooks, as a group of its own: Codex keys its trust of a hook by group and position.
                + (Self.answersPermissions ? [("PermissionRequest", NotifyServer.permissionHookCommand)] : [])
        default:
            return [("Notification", NotifyServer.hookCommand(title: name))]
        }
    }

    /// The file a failed change is about, as Settings names it.
    func file(failing error: Error) -> URL {
        (error as? IntegrationError) == .unreadableHooks ? hooksURL : configURL
    }

    var isInstalled: Bool {
        switch self {
        case .claudeCode, .gemini:
            return (try? Self.loadJSON(at: configURL)).map(JSONHook.isInstalled(in:)) ?? false
        case .codex:
            // The notify command is what makes Codex connected, as the notice hook does for Claude Code; the hooks
            // come with it, and are added at launch to a connection from before they existed.
            return (try? String(contentsOf: configURL, encoding: .utf8)).map(CodexNotify.isInstalled(in:)) ?? false
        case .openCode:
            return FileManager.default.fileExists(atPath: configURL.path)
        case .omp, .omo, .pi:
            return Self.isOurs(extension: configURL)
        }
    }

    /// Connecting, disconnecting and the update at launch all change the same files, so they take turns here.
    static let queue = DispatchQueue(label: "nunsseop.integrations")

    /// Connects the tool, or brings a connection from an older version up to date (a hook command without
    /// the X-App header, say), leaving a connection that's already current alone.
    func install() throws { try Self.queue.sync { try installNow() } }

    func uninstall() throws { try Self.queue.sync { try uninstallNow() } }

    func installNow() throws {
        // The hooks name this file; it has to be there before a tool runs one.
        NotifyServer.syncAuthHeader()
        switch self {
        case .claudeCode, .gemini:
            let settings = try Self.loadJSON(at: configURL)
            guard let updated = try JSONHook.updating(hooks, in: settings) else { return }
            try Self.writeJSON(updated, to: configURL)
        case .codex:
            // Both files are read and the changes worked out before anything is written, so one that can't be read
            // changes nothing. A connection that's already there is only refreshed, and doesn't wait for a hooks file
            // that can't be read.
            let text = try Self.loadText(at: configURL)
            let connected = CodexNotify.isInstalled(in: text)
            let notify = try connected ? nil : CodexNotify.adding(to: text)
            let agentHooks: [String: Any]?
            do {
                agentHooks = try JSONHook.updating(hooks, in: Self.loadJSON(at: hooksURL))
            } catch {
                guard connected else { throw IntegrationError.unreadableHooks }
                agentHooks = nil
            }
            let script = CodexNotify.scriptURL
            if (try? String(contentsOf: script, encoding: .utf8)) != CodexNotify.script {
                try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(CodexNotify.script.utf8).write(to: script, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            }
            if let notify { try Self.writeText(notify, to: configURL) }
            if let agentHooks { try Self.writeJSON(agentHooks, to: hooksURL) }
        case .openCode:
            guard (try? String(contentsOf: configURL, encoding: .utf8)) != Self.openCodePlugin else { return }
            // Through write(), so a plugin edited by hand is kept as a backup.
            try Self.write(Data(Self.openCodePlugin.utf8), to: configURL)
        case .omp, .omo, .pi:
            guard let agent = piAgent else { return }
            let extensionText = PiExtension.source(agent: agent)
            guard (try? String(contentsOf: configURL, encoding: .utf8)) != extensionText else { return }
            // A file of the same name that is not ours is kept as a backup. One of ours that differs is an older version or edited by
            // hand: it is kept too, but only where no backup is yet (a foreign file's backup is not given up for an upgrade).
            let backupExists = FileManager.default.fileExists(atPath: configURL.appendingPathExtension("nunsseop-backup").path)
            try Self.write(Data(extensionText.utf8), to: configURL, backup: !Self.isOurs(extension: configURL) || !backupExists)
        }
    }

    /// Whether the extension file is there and Nunsseop's.
    private static func isOurs(extension url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.hasPrefix(PiExtension.marker) == true
    }

    /// Updates every connected tool to this version's hook, script or plugin, in the background; the rest stay
    /// untouched, except for agent hooks of ours that a deleted notice hook or notify command left behind.
    static func updateConnected() {
        queue.async { updateConnectedNow() }
    }

    /// Whether a hook or script of an older version is in place that puts the token on curl's command line (see
    /// `NotifyServer`): a hook of Nunsseop's in Claude Code's, Gemini CLI's or Codex's hooks file, or the script Codex's
    /// notify command runs, or the one for terminal bells. Read only; the OpenCode plugin sends the token from inside
    /// OpenCode, in no command line.
    static var holdsLegacyTokenCommands: Bool {
        for tool in [NotifyIntegration.claudeCode, .gemini] {
            if let settings = try? loadJSON(at: tool.configURL), JSONHook.holdsLegacyToken(in: settings) { return true }
        }
        if let hooks = try? loadJSON(at: NotifyIntegration.codex.hooksURL), JSONHook.holdsLegacyToken(in: hooks) { return true }
        if let config = try? String(contentsOf: NotifyIntegration.codex.configURL, encoding: .utf8), CodexNotify.isInstalled(in: config),
           CodexNotify.isLegacy(script: try? String(contentsOf: CodexNotify.scriptURL, encoding: .utf8)) { return true }
        return TerminalBell.isLegacy(script: try? String(contentsOf: TerminalBell.scriptURL, encoding: .utf8))
    }

    /// With local notifications off nothing else refreshes what is connected, and the old commands would go on showing
    /// the token to every user; so they are replaced anyway, but only when there are any.
    static func replaceLegacyTokenCommands() {
        queue.async { replaceLegacyTokenCommandsNow() }
    }

    static func replaceLegacyTokenCommandsNow() {
        guard holdsLegacyTokenCommands else { return }
        TerminalBell.installIfPresent()
        updateConnectedNow()
    }

    /// The tools with hooks in a settings file, which a deleted notice hook or notify command can leave behind.
    private var leavesHooksBehind: Bool { [.claudeCode, .codex, .gemini].contains(self) }

    static func updateConnectedNow() {
        for tool in allCases {
            if tool.isInstalled {
                try? tool.installNow()
            } else if tool.leavesHooksBehind {
                try? tool.uninstallNow()
            }
        }
    }

    func uninstallNow() throws {
        switch self {
        case .claudeCode, .gemini:
            let settings = try Self.loadJSON(at: configURL)
            // Any of our hooks, not only the notice one, so agent hooks left behind by a deleted notice hook go too.
            guard JSONHook.holdsAny(in: settings) else { return }
            try Self.writeJSON(JSONHook.removing(from: settings), to: configURL)
        case .codex:
            let text = try Self.loadText(at: configURL)
            if CodexNotify.isInstalled(in: text) { try Self.writeText(CodexNotify.removing(from: text), to: configURL) }
            // Best effort: a hooks file that can't be read must not keep the notify command in place.
            if let agentHooks = try? Self.loadJSON(at: hooksURL), JSONHook.holdsAny(in: agentHooks) {
                try? Self.writeJSON(JSONHook.removing(from: agentHooks), to: hooksURL)
            }
        case .openCode:
            try? FileManager.default.removeItem(at: configURL)
        case .omp, .omo, .pi:
            if Self.isOurs(extension: configURL) { try? FileManager.default.removeItem(at: configURL) }
        }
    }

    // MARK: Files

    static func loadJSON(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw IntegrationError.unreadableConfig
        }
        return settings
    }

    private static func loadText(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func writeJSON(_ settings: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try write(data, to: url)
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// Keeps the previous file as `<name>.nunsseop-backup` before replacing it, unless `backup` says it isn't worth one.
    private static func write(_ data: Data, to url: URL, backup keep: Bool = true) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            if keep {
                let backup = url.appendingPathExtension("nunsseop-backup")
                try? fileManager.removeItem(at: backup)
                try fileManager.copyItem(at: url, to: backup)
            }
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }

    /// OpenCode loads every file in its plugins folder (see `OpenCodePlugin`).
    static var openCodePlugin: String { OpenCodePlugin.source() }
}

/// Claude Code and Gemini CLI both read hooks from a JSON settings file, as groups per event name.
/// A group can hold other tools' hooks and a matcher besides Nunsseop's, so everything here works on single hooks.
enum JSONHook {
    /// The hooks a tool should have: an event name and the command it runs, once each.
    typealias Table = [(event: String, command: String)]

    private static let noticeEvent = "Notification"

    /// Claude Code stops a hook that outlasts this; 10 minutes is its default, and the hook for permission prompts says so outright.
    static let permissionTimeout = 600

    private static func isPermission(command: String) -> Bool {
        command.contains("127.0.0.1:\(NotifyServer.port)/permission")
    }

    /// The tool that makes the permission hook run under PreToolUse. Never left out: the hook would otherwise start for every
    /// tool call.
    static let questionMatcher = "AskUserQuestion"

    /// The matcher of the group a hook of Nunsseop's goes in, nil for a group without one.
    private static func matcher(event: String, command: String) -> String? {
        event == "PreToolUse" && isPermission(command: command) ? questionMatcher : nil
    }

    /// Any of Nunsseop's hooks: the ones for the agents count (`/agent`) and for permission prompts (`/permission`),
    /// which are ours under any event, or the notice one (`/notify`), which is ours only under Notification. Under
    /// another event it's a command the user pasted from "Copy command for scripts", and stays.
    private static func isOurs(hook: Any, event: String) -> Bool {
        guard let command = (hook as? [String: Any])?["command"] as? String else { return false }
        return command.contains("127.0.0.1:\(NotifyServer.port)/agent") || isPermission(command: command)
            || (event == noticeEvent && command.contains("127.0.0.1:\(NotifyServer.port)/notify"))
    }

    private static func isNotice(hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains("127.0.0.1:\(NotifyServer.port)/notify") == true
    }

    /// Arrays are read as `[Any]`: an entry that isn't an object (a stray string, say) is skipped when looking for
    /// Nunsseop's hooks and written back as it was, instead of making the whole array look empty.
    private static func hooks(in group: Any) -> [Any] { (group as? [String: Any])?["hooks"] as? [Any] ?? [] }

    private static func holdsOurs(_ group: Any, event: String) -> Bool {
        hooks(in: group).contains { isOurs(hook: $0, event: event) }
    }

    /// Whether a hook of Nunsseop's still sends the token itself (`Authorization: Bearer …` on curl's command line)
    /// rather than the file with the header. Nothing of ours says "Bearer" any more.
    static func holdsLegacyToken(in settings: [String: Any]) -> Bool {
        (settings["hooks"] as? [String: Any] ?? [:]).contains { event, groups in
            ((groups as? [Any]) ?? []).contains { group in
                hooks(in: group).contains { hook in
                    isOurs(hook: hook, event: event) && ((hook as? [String: Any])?["command"] as? String)?.contains("Bearer") == true
                }
            }
        }
    }

    /// Whether any of Nunsseop's hooks is there, notice or not; what Disconnect has to clear.
    static func holdsAny(in settings: [String: Any]) -> Bool {
        (settings["hooks"] as? [String: Any] ?? [:]).contains { event, groups in
            ((groups as? [Any]) ?? []).contains { holdsOurs($0, event: event) }
        }
    }

    private static func groups(in settings: [String: Any], event: String) -> [Any] {
        (settings["hooks"] as? [String: Any])?[event] as? [Any] ?? []
    }

    /// Whether the notice hook is there, which is what makes a tool count as connected.
    static func isInstalled(in settings: [String: Any]) -> Bool {
        groups(in: settings, event: noticeEvent).contains { hooks(in: $0).contains(where: isNotice(hook:)) }
    }

    /// The settings with exactly the hooks in `table`, replacing older ones of Nunsseop's; nil when that's already so.
    static func updating(_ table: Table, in settings: [String: Any]) throws -> [String: Any]? {
        guard !isCurrent(table, in: settings) else { return nil }
        return try patching(table, in: settings) ?? adding(table, to: removing(from: settings))
    }

    /// The settings with the hooks of `table` that are missing added after the rest, an outdated agent command replaced where it
    /// stands, or with the permission hooks taken out when `table` has none, and every other group where it was; nil when more than
    /// that has to change. Codex keys its trust of a hook by the position of its group, so a hook that is already there must not move.
    private static func patching(_ table: Table, in settings: [String: Any]) throws -> [String: Any]? {
        let have = counted(entries(in: settings)), keys = entries(of: table), wanted = counted(keys)
        var seen: [Entry: Int] = [:]
        var missing = zip(table, keys).filter { _, key in
            seen[key, default: 0] += 1
            return seen[key]! > (have[key] ?? 0)
        }
        var surplus: [Entry: Int] = [:]
        for (key, count) in have where count > (wanted[key] ?? 0) { surplus[key] = count - (wanted[key] ?? 0) }
        var settings = settings
        // An agent command that has changed is rewritten in its own hook, under the same event and matcher.
        for (old, count) in surplus where isAgent(command: old.command) {
            for _ in 0..<count {
                guard let index = missing.firstIndex(where: { _, key in
                    key.event == old.event && key.matcher == old.matcher && isAgent(command: key.command)
                }) else { break }
                settings = replacing(old, with: missing[index].0.command, in: settings)
                missing.remove(at: index)
                surplus[old] = surplus[old]! - 1
            }
        }
        surplus = surplus.filter { $0.value > 0 }
        if surplus.isEmpty { return try adding(missing.map(\.0), to: settings) }
        guard missing.isEmpty, surplus.allSatisfy({ isPermission(command: $0.key.command) }),
              !table.contains(where: { isPermission(command: $0.command) }) else { return nil }
        return removing(from: settings) { hook, _ in isPermission(command: (hook as? [String: Any])?["command"] as? String ?? "") }
    }

    private static func isAgent(command: String) -> Bool { command.contains("127.0.0.1:\(NotifyServer.port)/agent") }

    /// The settings with the command of the first hook that is `old` (same event, matcher, command and timeout) replaced.
    private static func replacing(_ old: Entry, with command: String, in settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var events = settings["hooks"] as? [String: Any], var groups = events[old.event] as? [Any] else { return settings }
        for (g, entry) in groups.enumerated() {
            guard var group = entry as? [String: Any], (group["matcher"] as? String ?? "") == old.matcher,
                  var hooks = group["hooks"] as? [Any] else { continue }
            guard let h = hooks.firstIndex(where: { hook in
                guard let hook = hook as? [String: Any], isOurs(hook: hook, event: old.event) else { return false }
                return hook["command"] as? String == old.command && (hook["timeout"] as? NSNumber)?.intValue == old.timeout
            }), var hook = hooks[h] as? [String: Any] else { continue }
            hook["command"] = command
            hooks[h] = hook
            group["hooks"] = hooks
            groups[g] = group
            events[old.event] = groups
            settings["hooks"] = events
            return settings
        }
        return settings
    }

    static func updating(_ command: String, in settings: [String: Any]) throws -> [String: Any]? {
        try updating([(noticeEvent, command)], in: settings)
    }

    /// A hook of Nunsseop's as it stands in a settings file or a table, for comparing the two.
    private struct Entry: Hashable {
        let event: String
        let matcher: String
        let command: String
        let timeout: Int?
    }

    private static func entries(in settings: [String: Any]) -> [Entry] {
        let events = settings["hooks"] as? [String: Any] ?? [:]
        return events.flatMap { event, groups in
            ((groups as? [Any]) ?? []).flatMap { group in
                let matcher = (group as? [String: Any])?["matcher"] as? String ?? ""
                return hooks(in: group).filter { isOurs(hook: $0, event: event) }.map { hook in
                    let hook = hook as? [String: Any]
                    return Entry(event: event, matcher: matcher, command: hook?["command"] as? String ?? "",
                                 timeout: (hook?["timeout"] as? NSNumber)?.intValue)
                }
            }
        }
    }

    private static func entries(of table: Table) -> [Entry] {
        table.map { Entry(event: $0.event, matcher: matcher(event: $0.event, command: $0.command) ?? "", command: $0.command,
                          timeout: timeout(for: $0.command)) }
    }

    private static func counted(_ entries: [Entry]) -> [Entry: Int] {
        Dictionary(entries.map { ($0, 1) }, uniquingKeysWith: +)
    }

    /// Whether, across all events, Nunsseop's hooks are exactly the ones in `table`.
    static func isCurrent(_ table: Table, in settings: [String: Any]) -> Bool {
        counted(entries(in: settings)) == counted(entries(of: table))
    }

    static func isCurrent(_ command: String, in settings: [String: Any]) -> Bool {
        isCurrent([(noticeEvent, command)], in: settings)
    }

    private static func timeout(for command: String) -> Int? {
        isPermission(command: command) ? permissionTimeout : nil
    }

    /// The settings with the hooks added next to any hooks already under those events.
    static func adding(_ table: Table, to settings: [String: Any]) throws -> [String: Any] {
        var settings = settings
        guard var hooks = (settings["hooks"] ?? [String: Any]()) as? [String: Any] else {
            throw NotifyIntegration.IntegrationError.unreadableConfig
        }
        for (event, command) in table {
            guard var groups = (hooks[event] ?? [Any]()) as? [Any] else { throw NotifyIntegration.IntegrationError.unreadableConfig }
            var hook: [String: Any] = ["type": "command", "command": command]
            hook["timeout"] = timeout(for: command)
            var group: [String: Any] = ["hooks": [hook]]
            group["matcher"] = matcher(event: event, command: command)
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    static func adding(_ command: String, to settings: [String: Any]) throws -> [String: Any] {
        try adding([(noticeEvent, command)], to: settings)
    }

    /// The settings without Nunsseop's hooks, under every event. Other hooks in the same group, its matcher, and
    /// entries that aren't objects stay; a group is dropped only when nothing is left in it, and keys only when
    /// they end up empty.
    static func removing(from settings: [String: Any]) -> [String: Any] {
        removing(from: settings, matching: isOurs(hook:event:))
    }

    private static func removing(from settings: [String: Any], matching removed: (Any, String) -> Bool) -> [String: Any] {
        var settings = settings
        guard var events = settings["hooks"] as? [String: Any] else { return settings }
        var changed = false
        for (event, value) in events {
            guard let groups = value as? [Any],
                  groups.contains(where: { hooks(in: $0).contains { removed($0, event) } }) else { continue }
            changed = true
            let kept = groups.compactMap { entry -> Any? in
                guard var group = entry as? [String: Any], hooks(in: group).contains(where: { removed($0, event) }) else { return entry }
                let others = hooks(in: group).filter { !removed($0, event) }
                guard !others.isEmpty else { return nil }
                group["hooks"] = others
                return group
            }
            events[event] = kept.isEmpty ? nil : kept
        }
        guard changed else { return settings }
        settings["hooks"] = events.isEmpty ? nil : events
        return settings
    }
}

/// Codex runs one `notify` command per finished turn, with the event JSON as its last argument.
/// Nunsseop puts its script in front of whatever command was there, and the script runs that command afterwards.
enum CodexNotify {
    static var scriptURL: URL {
        NotifyServer.tokenURL.deletingLastPathComponent().appendingPathComponent("codex-notify.sh")
    }

    static let script = script(port: NotifyServer.port)

    /// curl gets the file with the header, not the token, which would be in its command line for any user to read.
    static func script(port: UInt16) -> String {
        """
        #!/bin/sh
        # Added by Nunsseop. Codex passes its event JSON as the last argument. This shows the turn in the notch,
        # then runs the notify command that was set before Nunsseop, if any, with the same arguments.
        for payload; do :; done
        printf '%s' "$payload" | plutil -extract last-assistant-message raw -o - - 2>/dev/null \\
            | curl -s -m 2 -X POST http://127.0.0.1:\(port)/notify \(NotifyServer.authHeaderOption) \\
                -H 'X-Title: Codex' -H "X-App: $__CFBundleIdentifier" --data-binary @- >/dev/null 2>&1
        [ $# -gt 1 ] && exec "$@"
        exit 0

        """
    }

    /// A script of an older version, which read the token and gave it to curl on its command line.
    static func isLegacy(script: String?) -> Bool { script?.contains("Bearer") == true }

    /// The root-level `notify = [...]` line: its index among the lines and its strings.
    /// Root-level keys come before the first `[table]` header.
    static func notifyLine(in lines: [String]) throws -> (index: Int, command: [String])? {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            guard trimmed.hasPrefix("notify"),
                  let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "notify" else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let command = parseStringArray(value) else { throw NotifyIntegration.IntegrationError.unreadableConfig }
            return (index, command)
        }
        return nil
    }

    static func isInstalled(in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        return ((try? notifyLine(in: lines)) ?? nil)?.command.contains(scriptURL.path) == true
    }

    static func adding(to text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        if let found = try notifyLine(in: lines) {
            lines[found.index] = line(for: ["/bin/sh", scriptURL.path] + found.command)
        } else {
            lines.insert(line(for: ["/bin/sh", scriptURL.path]), at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// Puts back the command that was there before, or removes the line if there was none.
    static func removing(from text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard let found = try notifyLine(in: lines),
              found.command.count >= 2, found.command[1] == scriptURL.path else { return text }
        let previous = Array(found.command.dropFirst(2))
        if previous.isEmpty { lines.remove(at: found.index) } else { lines[found.index] = line(for: previous) }
        return lines.joined(separator: "\n")
    }

    private static func line(for command: [String]) -> String {
        let quoted = command.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "notify = [" + quoted.joined(separator: ", ") + "]"
    }

    /// A one-line TOML array of basic ("…") or literal ('…') strings, optionally followed by a comment.
    static func parseStringArray(_ value: String) -> [String]? {
        var characters = Substring(value)
        guard characters.popFirst() == "[" else { return nil }
        var result: [String] = []
        while true {
            characters = characters.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = characters.popFirst() else { return nil }
            if first == "]" { break }
            if first == ",", !result.isEmpty { continue }
            guard first == "\"" || first == "'" else { return nil }
            var string = ""
            var closed = false
            while let c = characters.popFirst() {
                if c == first { closed = true; break }
                if c == "\\", first == "\"" {
                    switch characters.popFirst() {
                    case "\\"?: string.append("\\")
                    case "\""?: string.append("\"")
                    case "n"?: string.append("\n")
                    case "t"?: string.append("\t")
                    default: return nil
                    }
                } else {
                    string.append(c)
                }
            }
            guard closed else { return nil }
            result.append(string)
        }
        let rest = characters.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.hasPrefix("#") ? result : nil
    }
}
