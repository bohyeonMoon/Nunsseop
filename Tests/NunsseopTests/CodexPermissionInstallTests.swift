import Foundation
import Testing
@testable import Nunsseop

/// The permission hook in Codex's hooks.json, against a scratch home folder and a file shaped like a real one: other tools'
/// hooks in groups of their own, which Codex's trust of a hook is keyed to by position.
struct CodexPermissionInstallTests {
    private let codex = NotifyIntegration.codex
    private let claude = NotifyIntegration.claudeCode
    private let fileManager = FileManager.default
    private let command = NotifyServer.permissionHookCommand
    private let events = ["UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]

    private func on<T>(_ answers: Bool, _ body: () throws -> T) rethrows -> T {
        try NotifyIntegration.$permissionPromptsOverride.withValue(answers, operation: body)
    }

    private func hooksFile() throws -> [String: Any] { try NotifyIntegration.loadJSON(at: codex.hooksURL) }

    private func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    private func commands(_ group: [String: Any]) -> [String] {
        (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }

    private func same(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func modified(_ url: URL) -> Date? {
        try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// A hooks.json as Muxy and GitKraken write one: both in one PermissionRequest group, with a matcher and timeouts.
    private func others() -> [String: Any] {
        func group(_ commands: [String]) -> [String: Any] {
            ["matcher": "", "hooks": commands.map { ["type": "command", "command": $0, "timeout": 10] as [String: Any] }]
        }
        return ["hooks": [
            "PermissionRequest": [group(["muxy-codex-hook.sh permission-request # muxy-notification-hook", "gk ai hook run --host codex"])],
            "Stop": [group(["muxy-codex-hook.sh stop # muxy-notification-hook"]), group(["gk ai hook run --host codex"])],
            "PreToolUse": [group(["gk ai hook run --host codex"])],
        ]]
    }

    private func seed(_ home: URL) throws {
        try fileManager.createDirectory(at: codex.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"o3\"\n".utf8).write(to: codex.configURL)
        try NotifyIntegration.writeJSON(others(), to: codex.hooksURL)
    }

    @Test func theHookJoinsTheOtherPermissionGroupsAsOneOfItsOwnAfterTheAgentHook() throws {
        try withTempHome { home in
            try seed(home)
            try on(false) { try codex.installNow() }
            let before = try hooksFile()
            let agentOnly = try Data(contentsOf: codex.hooksURL)

            try on(true) { try codex.installNow() }

            let after = try hooksFile()
            #expect(JSONHook.isCurrent(on(true) { codex.hooks }, in: after))
            // Every group that was there is where it was, byte for byte; ours is one more at the end, with no matcher.
            for event in events + ["PreToolUse"] {
                let was = groups(before, event), now = groups(after, event)
                #expect(now.count == was.count + (event == "PermissionRequest" ? 1 : 0), "\(event)")
                #expect(zip(was, now).allSatisfy { same($0, $1) }, "\(event)")
            }
            let permission = groups(after, "PermissionRequest")
            #expect(permission.count == 3)
            #expect(commands(permission[0]).count == 2 && permission[0]["matcher"] as? String == "")
            #expect(commands(permission[1]) == [NotifyServer.agentHookCommand(for: .codex)])
            let added = try #require(permission.last)
            #expect(added["matcher"] == nil && commands(added) == [command])
            let hook = try #require((added["hooks"] as? [[String: Any]])?.first)
            #expect(hook["type"] as? String == "command" && hook["timeout"] as? Int == 600)
            // The first file is kept as the backup of the change.
            #expect(try Data(contentsOf: codex.hooksURL.appendingPathExtension("nunsseop-backup")) == agentOnly)
            // The agent hook's command is the one it always was, in its group and nowhere else.
            let agentCommands = events.flatMap { event in groups(after, event).flatMap(commands) }.filter { $0 == NotifyServer.agentHookCommand(for: .codex) }
            #expect(agentCommands.count == events.count)
        }
    }

    @Test func installingAgainRewritesNothing() throws {
        try withTempHome { home in
            try seed(home)
            try on(true) { try codex.installNow() }
            let bytes = try Data(contentsOf: codex.hooksURL), date = modified(codex.hooksURL)
            try on(true) { try codex.installNow() }
            try on(true) { NotifyIntegration.updateConnectedNow() }
            #expect(try Data(contentsOf: codex.hooksURL) == bytes && modified(codex.hooksURL) == date)
        }
    }

    @Test func aConnectionFromBeforeGetsTheHookAtLaunchWithoutMovingAnythingElse() throws {
        try withTempHome { home in
            try seed(home)
            try on(false) { try codex.installNow() }
            let before = try hooksFile()
            #expect(!JSONHook.isCurrent(on(true) { codex.hooks }, in: before))

            try on(true) { NotifyIntegration.updateConnectedNow() }

            let after = try hooksFile()
            #expect(JSONHook.isCurrent(on(true) { codex.hooks }, in: after))
            #expect(codex.isInstalled)
            for event in ["UserPromptSubmit", "Stop", "Interrupt", "SessionEnd", "PreToolUse"] {
                #expect(same(groups(before, event), groups(after, event)), "\(event)")
            }
            #expect(zip(groups(before, "PermissionRequest"), groups(after, "PermissionRequest")).allSatisfy { same($0, $1) })
        }
    }

    @Test func turningTheSettingOffTakesOnlyTheHookOutAndLeavesTheFileAsItWasWithoutIt() throws {
        try withTempHome { home in
            try seed(home)
            try on(false) { try codex.installNow() }
            let agentOnly = try hooksFile()
            try on(true) { NotifyIntegration.updateConnectedNow() }
            #expect(groups(try hooksFile(), "PermissionRequest").count == 3)

            try on(false) { NotifyIntegration.updateConnectedNow() }

            let after = try hooksFile()
            #expect(same(agentOnly, after))
            #expect(!events.contains { event in groups(after, event).contains { commands($0).contains(command) } })
            #expect(JSONHook.isCurrent(on(false) { codex.hooks }, in: after) && codex.isInstalled)
            // And on again puts it back.
            try on(true) { NotifyIntegration.updateConnectedNow() }
            #expect(JSONHook.isCurrent(on(true) { codex.hooks }, in: try hooksFile()))
        }
    }

    @Test func disconnectingTakesTheHookAndTheAgentHooksAndNothingOfOtherTools() throws {
        try withTempHome { home in
            try seed(home)
            try on(true) { try codex.installNow() }
            try on(true) { try codex.uninstallNow() }
            let after = try hooksFile()
            #expect(!JSONHook.holdsAny(in: after) && !codex.isInstalled)
            #expect(same(after, others()))
        }
    }

    @Test func aCodexThatIsNotConnectedKeepsNoPermissionHookEvenWhenTheSettingIsOn() throws {
        try withTempHome { home in
            try seed(home)
            // Hooks of ours without the notify command, as a deleted connection leaves them.
            try NotifyIntegration.writeJSON(JSONHook.adding(on(true) { codex.hooks }, to: others()), to: codex.hooksURL)
            #expect(!codex.isInstalled)
            try on(true) { NotifyIntegration.updateConnectedNow() }
            #expect(same(try hooksFile(), others()))
        }
    }

    @Test func theHookIsInTheTableOfNoOtherToolsThanClaudeCodeAndCodex() {
        on(true) {
            #expect(codex.hooks.filter { $0.command == command }.map(\.event) == ["PermissionRequest"])
            #expect(NotifyIntegration.gemini.hooks.allSatisfy { $0.command != command })
            #expect(claude.hooks.filter { $0.command == command }.map(\.event) == ["PermissionRequest", "PreToolUse"])
        }
        on(false) {
            #expect(codex.hooks.allSatisfy { $0.command != command } && claude.hooks.allSatisfy { $0.command != command })
        }
    }

    @Test func claudeCodesFileIsNotTouchedByCodexsConnection() throws {
        try withTempHome { home in
            try seed(home)
            try on(true) { try codex.installNow() }
            #expect(!fileManager.fileExists(atPath: claude.configURL.path))
        }
    }

    // MARK: Adding or removing a hook leaves the groups in place, for every tool

    @Test func addingTheHooksOfAnOlderConnectionMovesNoGroupAndAnOutdatedCommandStillReplacesTheWholeSet() throws {
        let agent = NotifyServer.agentHookCommand(for: .codex)
        let table: JSONHook.Table = [("Stop", agent), ("PermissionRequest", agent), ("PermissionRequest", command)]
        let start = try JSONHook.adding(Array(table.prefix(2)), to: others())
        let grown = try #require(try JSONHook.updating(table, in: start))
        #expect(JSONHook.isCurrent(table, in: grown))
        for event in ["Stop", "PermissionRequest"] {
            #expect(zip(groups(start, event), groups(grown, event)).allSatisfy { same($0, $1) }, "\(event)")
        }
        #expect(try JSONHook.updating(table, in: grown) == nil)

        // A hook of ours that is not in the table any more, and is not a permission hook, still means a full rewrite.
        let outdated = try JSONHook.adding([("Stop", agent + " # old")], to: start)
        let fixed = try #require(try JSONHook.updating(table, in: outdated))
        #expect(JSONHook.isCurrent(table, in: fixed))
        #expect(!groups(fixed, "Stop").contains { commands($0).contains(agent + " # old") })
    }
}
