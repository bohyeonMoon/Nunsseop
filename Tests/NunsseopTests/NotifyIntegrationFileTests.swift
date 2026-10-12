import Foundation
import Testing
@testable import Nunsseop

/// The real-file side of connecting a tool, against a scratch home folder.
struct NotifyIntegrationFileTests {
    private let claude = NotifyIntegration.claudeCode
    private let fileManager = FileManager.default

    private func backup(of url: URL) -> URL { url.appendingPathExtension("nunsseop-backup") }

    private func put(_ text: String, at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    private func modified(_ url: URL) -> Date? {
        try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func names(in folder: URL) -> [String]? { try? fileManager.contentsOfDirectory(atPath: folder.path) }

    private func sameJSON(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }

    private let userHooks = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine.sh"}]}]},"model":"opus"}"#

    // MARK: Install

    @Test func installKeepsTheOtherSettingsAsTheyWereAndBacksUpFirst() throws {
        try withTempHome { _ in
            let seed = #"{"model":"opus","flag":true,"n":1.5,"nil":null,"path":"/a/b","name":"한글","permissions":{"allow":["Bash(ls)"]}}"#
            try put(seed, at: claude.configURL)
            try claude.installNow()

            let settings = try NotifyIntegration.loadJSON(at: claude.configURL)
            #expect(JSONHook.isCurrent(claude.hooks, in: settings))
            #expect(settings["model"] as? String == "opus")
            #expect(settings["n"] as? Double == 1.5)
            #expect(settings["nil"] is NSNull)
            #expect(settings["path"] as? String == "/a/b")
            #expect(settings["name"] as? String == "한글")
            #expect(settings["permissions"] as? [String: [String]] == ["allow": ["Bash(ls)"]])
            let written = try String(contentsOf: claude.configURL, encoding: .utf8)
            #expect(written.contains(#""flag" : true"#) && written.contains(#""n" : 1.5"#) && written.contains(#""nil" : null"#))
            #expect(written.contains(#""path" : "/a/b""#) && written.contains(#""name" : "한글""#))
            #expect(bytes(backup(of: claude.configURL)) == Data(seed.utf8))
        }
    }

    @Test func installingAgainLeavesTheFileAndItsBackupAlone() throws {
        try withTempHome { _ in
            let seed = #"{"model":"opus"}"#
            try put(seed, at: claude.configURL)
            try claude.installNow()
            let installed = bytes(claude.configURL), date = modified(claude.configURL)
            try claude.installNow()
            #expect(bytes(claude.configURL) == installed)
            #expect(modified(claude.configURL) == date)
            #expect(bytes(backup(of: claude.configURL)) == Data(seed.utf8))
        }
    }

    @Test func launchBringsAnOldClaudeCodeAgentCommandUpToDateInPlace() throws {
        try withTempHome { _ in
            let old = NotifyServer.agentHookCommand.replacingOccurrences(of: #"-H "X-Pid: $PPID" "#, with: "")
            let mine: [String: Any] = ["hooks": [["type": "command", "command": "mine.sh"]]]
            let table: JSONHook.Table = [("Notification", NotifyServer.hookCommand(title: "Claude Code"))]
                + ["Notification", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"].map { ($0, old) }
            try NotifyIntegration.writeJSON(JSONHook.adding(table, to: ["hooks": ["Stop": [mine]], "model": "opus"]), to: claude.configURL)
            #expect(claude.isInstalled)

            NotifyIntegration.updateConnectedNow()

            let settings = try NotifyIntegration.loadJSON(at: claude.configURL)
            #expect(JSONHook.isCurrent(claude.hooks, in: settings))
            let hooks = try #require(settings["hooks"] as? [String: Any])
            let commands = { (event: String) in
                ((hooks[event] as? [[String: Any]]) ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
            }
            // One agent command per event, the new one, and nothing of the old; the user's hook stays.
            #expect(commands("Stop") == ["mine.sh", NotifyServer.agentHookCommand])
            #expect(commands("SessionStart") == [NotifyServer.agentHookCommand])
            #expect(commands("SessionEnd") == [NotifyServer.agentHookCommand])
            #expect(hooks.values.allSatisfy { value in
                ((value as? [[String: Any]]) ?? []).allSatisfy { ($0["hooks"] as? [[String: Any]] ?? []).allSatisfy { ($0["command"] as? String) != old } }
            })
            #expect(settings["model"] as? String == "opus")
        }
    }

    @Test func installCreatesTheFileAndFolderWhenThereIsNone() throws {
        try withTempHome { home in
            try claude.installNow()
            let settings = try NotifyIntegration.loadJSON(at: claude.configURL)
            #expect(JSONHook.isCurrent(claude.hooks, in: settings))
            #expect(!fileManager.fileExists(atPath: backup(of: claude.configURL).path))

            try NotifyIntegration.gemini.installNow()
            let gemini = try NotifyIntegration.loadJSON(at: home.appendingPathComponent(".gemini/settings.json"))
            #expect(JSONHook.isCurrent(NotifyIntegration.gemini.hooks, in: gemini))
            #expect(JSONHook.isInstalled(in: gemini))
        }
    }

    @Test func aConfigThatCantBeReadIsNeverOverwritten() throws {
        try withTempHome { _ in
            for seed in [#"{"hooks": "#, "[1,2]", "// c\n{}", ""] {
                try put(seed, at: claude.configURL)
                #expect(throws: (any Error).self, "\(seed)") { try claude.installNow() }
                #expect(bytes(claude.configURL) == Data(seed.utf8), "\(seed)")
                #expect(!fileManager.fileExists(atPath: backup(of: claude.configURL).path), "\(seed)")
                #expect(!claude.isInstalled)
            }
            // A hooks key of another shape is refused too.
            let odd = #"{"hooks":"nope"}"#
            try put(odd, at: claude.configURL)
            #expect(throws: NotifyIntegration.IntegrationError.self) { try claude.installNow() }
            #expect(bytes(claude.configURL) == Data(odd.utf8))
        }
    }

    // MARK: Uninstall

    @Test func uninstallLeavesOnlyTheUsersOwnHooks() throws {
        try withTempHome { _ in
            try put(userHooks, at: claude.configURL)
            let original = try NotifyIntegration.loadJSON(at: claude.configURL)
            try claude.installNow()
            #expect(claude.isInstalled)
            try claude.uninstallNow()
            #expect(!claude.isInstalled)
            #expect(sameJSON(try NotifyIntegration.loadJSON(at: claude.configURL), original))
        }
    }

    @Test func uninstallDropsTheHooksKeyWhenNothingIsLeftInIt() throws {
        try withTempHome { _ in
            try put(#"{"model":"opus"}"#, at: claude.configURL)
            try claude.installNow()
            try claude.uninstallNow()
            let settings = try NotifyIntegration.loadJSON(at: claude.configURL)
            #expect(sameJSON(settings, ["model": "opus"]))
        }
    }

    @Test func uninstallWithNoConfigChangesNothing() throws {
        try withTempHome { home in
            try claude.uninstallNow()
            try NotifyIntegration.gemini.uninstallNow()
            try NotifyIntegration.codex.uninstallNow()
            #expect(names(in: home) == [])
        }
    }

    @Test func uninstallLeavesAFileWithoutOurHooksUntouched() throws {
        try withTempHome { _ in
            try put(userHooks, at: claude.configURL)
            let date = modified(claude.configURL)
            try claude.uninstallNow()
            #expect(bytes(claude.configURL) == Data(userHooks.utf8))
            #expect(modified(claude.configURL) == date)
            #expect(!fileManager.fileExists(atPath: backup(of: claude.configURL).path))
        }
    }

    // MARK: Codex hooks

    private let codex = NotifyIntegration.codex
    private let codexEvents = ["UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]

    /// Another tool's entries as Muxy, GitKraken and herdr write them into ~/.codex/hooks.json: a matcher and a timeout.
    private func othersHooks() -> [String: Any] {
        func group(_ commands: [String]) -> [String: Any] {
            ["matcher": "", "hooks": commands.map { ["type": "command", "command": $0, "timeout": 10] as [String: Any] }]
        }
        return ["hooks": [
            "PermissionRequest": [group(["muxy-codex-hook.sh permission-request # muxy-notification-hook", "gk ai hook run --host codex"])],
            "Stop": [group(["muxy-codex-hook.sh stop # muxy-notification-hook"]), group(["gk ai hook run --host codex"])],
            "PreToolUse": [group(["gk ai hook run --host codex"])],
            "SessionStart": [group(["bash herdr-agent-state.sh session"])],
        ]]
    }

    private func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    @Test func connectingCodexAddsItsHooksNextToTheOtherToolsAndKeepsTheirs() throws {
        try withTempHome { home in
            let hooksURL = home.appendingPathComponent(".codex/hooks.json")
            try put("model = \"o3\"\n", at: codex.configURL)
            let others = othersHooks()
            try NotifyIntegration.writeJSON(others, to: hooksURL)
            let seed = try #require(bytes(hooksURL))

            try codex.installNow()

            let settings = try NotifyIntegration.loadJSON(at: hooksURL)
            #expect(JSONHook.isCurrent(codex.hooks, in: settings))
            #expect(codex.hooks.map(\.event).sorted() == codexEvents.sorted())
            for event in codexEvents {
                let before = groups(others, event), after = groups(settings, event)
                // The other tools' groups stay first and untouched; ours is one more group after them.
                #expect(after.count == before.count + 1, "\(event)")
                #expect(zip(before, after).allSatisfy { sameJSON($0, $1) }, "\(event)")
                let ours = try #require(after.last)
                #expect(ours["matcher"] == nil)
                #expect(((ours["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String }) == [NotifyServer.agentHookCommand(for: .codex)])
            }
            for event in ["PreToolUse", "SessionStart"] {
                #expect(sameJSON(["g": groups(settings, event)], ["g": groups(others, event)]), "\(event)")
            }
            #expect(bytes(backup(of: hooksURL)) == seed)
            // The notice side is the legacy notify command, as before.
            #expect(CodexNotify.isInstalled(in: text(codex.configURL) ?? ""))
            #expect(codex.isInstalled)
            // Claude Code's settings are nobody's business here.
            #expect(!fileManager.fileExists(atPath: claude.configURL.path))
        }
    }

    @Test func disconnectingCodexRemovesOnlyItsHooks() throws {
        try withTempHome { home in
            let hooksURL = home.appendingPathComponent(".codex/hooks.json")
            try put("model = \"o3\"\n", at: codex.configURL)
            let others = othersHooks()
            try NotifyIntegration.writeJSON(others, to: hooksURL)
            try codex.installNow()
            #expect(codex.isInstalled)

            try codex.uninstallNow()

            #expect(!codex.isInstalled)
            #expect(!JSONHook.holdsAny(in: try NotifyIntegration.loadJSON(at: hooksURL)))
            #expect(sameJSON(try NotifyIntegration.loadJSON(at: hooksURL), others))
            #expect(text(codex.configURL) == "model = \"o3\"\n")
        }
    }

    @Test func connectingCodexCreatesHooksJSONAndDisconnectingLeavesNoneOfOurs() throws {
        try withTempHome { home in
            let hooksURL = home.appendingPathComponent(".codex/hooks.json")
            try codex.installNow()
            let settings = try NotifyIntegration.loadJSON(at: hooksURL)
            #expect(JSONHook.isCurrent(codex.hooks, in: settings))
            #expect(!fileManager.fileExists(atPath: backup(of: hooksURL).path))
            for event in codexEvents { #expect(groups(settings, event).count == 1, "\(event)") }

            // Again: nothing is rewritten.
            let installed = bytes(hooksURL), date = modified(hooksURL)
            try codex.installNow()
            #expect(bytes(hooksURL) == installed && modified(hooksURL) == date)
            #expect(!fileManager.fileExists(atPath: backup(of: hooksURL).path))

            try codex.uninstallNow()
            #expect(try NotifyIntegration.loadJSON(at: hooksURL).isEmpty)
            #expect(!codex.isInstalled)
        }
    }

    @Test func codexCountsAsConnectedThroughItsNotifyCommandAlone() throws {
        try withTempHome { home in
            let hooksURL = home.appendingPathComponent(".codex/hooks.json")
            // Only the hooks: not connected, since Connect is what puts both in.
            try NotifyIntegration.writeJSON(JSONHook.adding(codex.hooks, to: [:]), to: hooksURL)
            #expect(!codex.isInstalled)
            // A connection from before the hooks existed still counts, and the next launch brings the hooks.
            try fileManager.removeItem(at: hooksURL)
            try put(CodexNotify.adding(to: ""), at: codex.configURL)
            #expect(codex.isInstalled)
        }
    }

    @Test func aHooksFileThatCantBeReadStopsConnectingCodexBeforeAnythingIsWritten() throws {
        try withTempHome { home in
            let hooksURL = home.appendingPathComponent(".codex/hooks.json")
            try put("model = \"o3\"\n", at: codex.configURL)
            for seed in [#"{"hooks": "#, "[1]", #"{"hooks":"nope"}"#] {
                try put(seed, at: hooksURL)
                #expect(throws: (any Error).self, "\(seed)") { try codex.installNow() }
                #expect(bytes(hooksURL) == Data(seed.utf8), "\(seed)")
                #expect(text(codex.configURL) == "model = \"o3\"\n", "\(seed)")
                #expect(!fileManager.fileExists(atPath: CodexNotify.scriptURL.path), "\(seed)")
                #expect(!codex.isInstalled)
            }
        }
    }

    @Test func theErrorForAHooksFileThatCantBeReadNamesHooksJSON() throws {
        try withTempHome { home in
            try put("model = \"o3\"\n", at: codex.configURL)
            try put("[1]", at: codex.hooksURL)
            let error = try #require(throws: NotifyIntegration.IntegrationError.self) { try codex.installNow() }
            #expect(codex.file(failing: error) == codex.hooksURL)
            #expect(codex.hooksURL.lastPathComponent == "hooks.json")
            // A config that can't be read is its own file's error.
            try put("notify = nope\n", at: codex.configURL)
            let configError = try #require(throws: NotifyIntegration.IntegrationError.self) { try codex.installNow() }
            #expect(codex.file(failing: configError) == codex.configURL)
        }
    }

    @Test func disconnectingCodexWorksWithAHooksFileThatCantBeRead() throws {
        try withTempHome { home in
            for seed in ["", "// c\n{}", "[1]", #"{"hooks": "#, #"{"hooks":"nope"}"#] {
                try put(CodexNotify.adding(to: "model = \"o3\"\n"), at: codex.configURL)
                try put(seed, at: codex.hooksURL)
                try codex.uninstallNow()
                #expect(text(codex.configURL) == "model = \"o3\"\n", "\(seed)")
                #expect(!codex.isInstalled, "\(seed)")
                #expect(bytes(codex.hooksURL) == Data(seed.utf8), "\(seed)")
            }
        }
    }

    @Test func launchRefreshesTheCodexScriptWithAHooksFileThatCantBeRead() throws {
        try withTempHome { home in
            for seed in ["", "// c\n{}", "[1]", #"{"hooks":"nope"}"#] {
                let configText = try CodexNotify.adding(to: "model = \"o3\"\n")
                try put(configText, at: codex.configURL)
                try put("#!/bin/sh\necho old\n", at: CodexNotify.scriptURL)
                try put(seed, at: codex.hooksURL)
                NotifyIntegration.updateConnectedNow()
                #expect(text(CodexNotify.scriptURL) == CodexNotify.script, "\(seed)")
                #expect(text(codex.configURL) == configText, "\(seed)")
                #expect(bytes(codex.hooksURL) == Data(seed.utf8), "\(seed)")
            }
        }
    }

    @Test func launchBringsAnOlderCodexConnectionTheHooks() throws {
        try withTempHome { home in
            let hooksURL = home.appendingPathComponent(".codex/hooks.json")
            try put(CodexNotify.adding(to: "model = \"o3\"\n"), at: codex.configURL)
            let others = othersHooks()
            try NotifyIntegration.writeJSON(others, to: hooksURL)
            NotifyIntegration.updateConnectedNow()
            #expect(JSONHook.isCurrent(codex.hooks, in: try NotifyIntegration.loadJSON(at: hooksURL)))

            // Our hook of an older version is replaced, not doubled.
            var stale = try NotifyIntegration.loadJSON(at: hooksURL)
            stale = try JSONHook.adding([("Stop", "curl http://127.0.0.1:\(NotifyServer.port)/agent -H 'X-Old: 1'")],
                                        to: JSONHook.removing(from: stale))
            try NotifyIntegration.writeJSON(stale, to: hooksURL)
            NotifyIntegration.updateConnectedNow()
            let settings = try NotifyIntegration.loadJSON(at: hooksURL)
            #expect(JSONHook.isCurrent(codex.hooks, in: settings))
            #expect(groups(settings, "Stop").count == groups(others, "Stop").count + 1)
        }
    }

    @Test func launchClearsCodexHooksLeftBehindWithoutTheNotifyCommand() throws {
        try withTempHome { home in
            let hooksURL = home.appendingPathComponent(".codex/hooks.json")
            let others = othersHooks()
            try NotifyIntegration.writeJSON(JSONHook.adding(codex.hooks, to: others), to: hooksURL)
            NotifyIntegration.updateConnectedNow()
            #expect(sameJSON(try NotifyIntegration.loadJSON(at: hooksURL), others))
        }
    }

    @Test func launchLeavesAHooksFileWithNoHooksOfOursAlone() throws {
        try withTempHome { home in
            let hooksURL = home.appendingPathComponent(".codex/hooks.json")
            try NotifyIntegration.writeJSON(othersHooks(), to: hooksURL)
            let seed = bytes(hooksURL), date = modified(hooksURL)
            NotifyIntegration.updateConnectedNow()
            #expect(bytes(hooksURL) == seed && modified(hooksURL) == date)
            #expect(!fileManager.fileExists(atPath: backup(of: hooksURL).path))
        }
    }

    // MARK: Update at launch

    @Test func launchBringsAnOlderNoticeHookUpToDate() throws {
        try withTempHome { _ in
            let old = "plutil -extract message raw -o - - | curl -s http://127.0.0.1:\(NotifyServer.port)/notify --data-binary @-"
            let seed: [String: Any] = ["hooks": ["Notification": [["hooks": [["type": "command", "command": old]]],
                                                                 ["hooks": [["type": "command", "command": "mine.sh"]]]]]]
            try NotifyIntegration.writeJSON(seed, to: claude.configURL)
            NotifyIntegration.updateConnectedNow()

            let settings = try NotifyIntegration.loadJSON(at: claude.configURL)
            #expect(JSONHook.isCurrent(claude.hooks, in: settings))
            let groups = try #require((settings["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]])
            let commands = groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
            #expect(commands.contains("mine.sh") && !commands.contains(old))
        }
    }

    @Test func launchClearsAgentHooksLeftBehindByADeletedNoticeHook() throws {
        try withTempHome { _ in
            let mine: [String: Any] = ["hooks": [["type": "command", "command": "mine.sh"]]]
            let seed = try JSONHook.adding([("Stop", NotifyServer.agentHookCommand), ("UserPromptSubmit", NotifyServer.agentHookCommand)],
                                           to: ["hooks": ["Stop": [mine]], "model": "opus"])
            try NotifyIntegration.writeJSON(seed, to: claude.configURL)
            #expect(JSONHook.holdsAny(in: seed) && !JSONHook.isInstalled(in: seed))
            NotifyIntegration.updateConnectedNow()

            let settings = try NotifyIntegration.loadJSON(at: claude.configURL)
            #expect(!JSONHook.holdsAny(in: settings))
            #expect(sameJSON(settings, ["hooks": ["Stop": [mine]], "model": "opus"]))
        }
    }

    @Test func launchLeavesWhatWasNeverConnectedAlone() throws {
        try withTempHome { home in
            try put(userHooks, at: claude.configURL)
            let date = modified(claude.configURL)
            NotifyIntegration.updateConnectedNow()
            #expect(bytes(claude.configURL) == Data(userHooks.utf8))
            #expect(modified(claude.configURL) == date)
            #expect(!fileManager.fileExists(atPath: backup(of: claude.configURL).path))
            #expect(!fileManager.fileExists(atPath: home.appendingPathComponent(".gemini").path))
        }
    }

    @Test func launchLeavesAConfigItCantReadAlone() throws {
        try withTempHome { _ in
            let seed = #"{"hooks": "#
            try put(seed, at: claude.configURL)
            NotifyIntegration.updateConnectedNow()
            #expect(bytes(claude.configURL) == Data(seed.utf8))
            #expect(!fileManager.fileExists(atPath: backup(of: claude.configURL).path))
        }
    }

    @Test func launchWithNothingInstalledCreatesNothing() throws {
        try withTempHome { home in
            NotifyIntegration.updateConnectedNow()
            #expect(names(in: home) == [])
        }
    }

    @Test func launchRewritesAnOldCodexScriptButNotTheConfig() throws {
        try withTempHome { home in
            let config = NotifyIntegration.codex.configURL
            let configText = try CodexNotify.adding(to: "model = \"o3\"\n")
            try put(configText, at: config)
            try put("#!/bin/sh\necho old\n", at: CodexNotify.scriptURL)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: CodexNotify.scriptURL.path)
            NotifyIntegration.updateConnectedNow()

            #expect(CodexNotify.scriptURL.path == home.appendingPathComponent("Library/Application Support/Nunsseop/codex-notify.sh").path)
            #expect(text(CodexNotify.scriptURL) == CodexNotify.script)
            #expect((try? fileManager.attributesOfItem(atPath: CodexNotify.scriptURL.path))?[.posixPermissions] as? Int == 0o755)
            #expect(self.text(config) == configText)
            #expect(!fileManager.fileExists(atPath: backup(of: config).path))
        }
    }

    @Test func launchReplacesAnEditedOpenCodePluginAndKeepsTheEdit() throws {
        try withTempHome { _ in
            let plugin = NotifyIntegration.openCode.configURL
            try put("// my edit\n", at: plugin)
            NotifyIntegration.updateConnectedNow()
            #expect(text(plugin) == NotifyIntegration.openCodePlugin)
            #expect(plugin.lastPathComponent == "nunsseop.js")
            #expect(text(backup(of: plugin)) == "// my edit\n")
        }
    }
}
