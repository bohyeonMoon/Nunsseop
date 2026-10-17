import Foundation
import Testing
@testable import Nunsseop

/// The permission hook in Claude Code's settings, against a scratch home folder.
struct PermissionInstallTests {
    private let claude = NotifyIntegration.claudeCode

    private func settings() throws -> [String: Any] { try NotifyIntegration.loadJSON(at: claude.configURL) }

    private func hooks(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        (((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    private func on<T>(_ answers: Bool, _ body: () throws -> T) rethrows -> T {
        try NotifyIntegration.$permissionPromptsOverride.withValue(answers, operation: body)
    }

    @Test func connectingAddsTheHookWithItsTimeoutSetOutright() throws {
        try withTempHome { _ in
            try on(true) {
                try claude.installNow()
                let permission = hooks(try settings(), "PermissionRequest")
                #expect(permission.count == 1)
                #expect(permission[0]["command"] as? String == NotifyServer.permissionHookCommand)
                #expect(permission[0]["timeout"] as? Int == 600)
                #expect(permission[0]["type"] as? String == "command")
                #expect(JSONHook.isCurrent(claude.hooks, in: try settings()))
                #expect(claude.isInstalled)
                // The others keep the timeout they always had: none.
                #expect(hooks(try settings(), "Stop").allSatisfy { $0["timeout"] == nil })
            }
        }
    }

    @Test func theTableHoldsTheHookOnlyWhileTheSettingIsOn() {
        let events = { (on: Bool) in self.on(on) { self.claude.hooks.map(\.event).filter { $0 == "PermissionRequest" } } }
        #expect(events(true) == ["PermissionRequest"])
        #expect(events(false).isEmpty)
        #expect(on(true) { NotifyIntegration.codex.hooks.count } == on(false) { NotifyIntegration.codex.hooks.count } + 1)
        // Gemini CLI's hooks are a notice and its sessions, never approvals.
        #expect(on(true) { NotifyIntegration.gemini.hooks.count } == on(false) { NotifyIntegration.gemini.hooks.count })
    }

    @Test func turningTheSettingOffRemovesTheHookAndOnPutsItBack() throws {
        try withTempHome { _ in
            try on(true) { try claude.installNow() }
            let withHook = try settings()

            on(false) { NotifyIntegration.updateConnectedNow() }
            let without = try settings()
            #expect(without["hooks"] != nil)
            #expect(hooks(without, "PermissionRequest").isEmpty)
            #expect((without["hooks"] as? [String: Any])?["PermissionRequest"] == nil)
            #expect(claude.isInstalled)
            #expect(hooks(without, "Notification").count == hooks(withHook, "Notification").count)
            #expect(hooks(without, "Stop").count == 1)
            on(false) { #expect(JSONHook.isCurrent(claude.hooks, in: without)) }

            on(true) { NotifyIntegration.updateConnectedNow() }
            #expect(hooks(try settings(), "PermissionRequest").count == 1)
            #expect(JSONHook.isCurrent(on(true) { claude.hooks }, in: try settings()))
        }
    }

    @Test func theUsersOwnPermissionHooksAndSettingsSurviveEveryChange() throws {
        try withTempHome { home in
            let mine = #"{"model":"opus","hooks":{"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"mine.sh","timeout":5}]}]}}"#
            try FileManager.default.createDirectory(at: claude.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(mine.utf8).write(to: claude.configURL)

            try on(true) { try claude.installNow() }
            #expect(hooks(try settings(), "PermissionRequest").compactMap { $0["command"] as? String }
                    == ["mine.sh", NotifyServer.permissionHookCommand])

            on(false) { NotifyIntegration.updateConnectedNow() }
            var kept = hooks(try settings(), "PermissionRequest")
            #expect(kept.count == 1 && kept[0]["command"] as? String == "mine.sh" && kept[0]["timeout"] as? Int == 5)
            #expect(try settings()["model"] as? String == "opus")

            try on(true) { try claude.installNow() }
            try claude.uninstallNow()
            kept = hooks(try settings(), "PermissionRequest")
            #expect(kept.count == 1 && kept[0]["command"] as? String == "mine.sh")
            #expect(!JSONHook.holdsAny(in: try settings()))
            _ = home
        }
    }

    @Test func disconnectingTakesTheHookWithIt() throws {
        try withTempHome { _ in
            try on(true) { try claude.installNow() }
            try claude.uninstallNow()
            #expect(try settings()["hooks"] == nil)
            #expect(!claude.isInstalled)
            // A hook left behind without the notice hook goes at the next refresh, as the agent hooks do.
            try NotifyIntegration.writeJSON(JSONHook.adding([("PermissionRequest", NotifyServer.permissionHookCommand)], to: [:]),
                                            to: claude.configURL)
            let leftBehind = try settings()
            #expect(!claude.isInstalled && JSONHook.holdsAny(in: leftBehind))
            on(true) { NotifyIntegration.updateConnectedNow() }
            let refreshed = try settings()
            #expect(!JSONHook.holdsAny(in: refreshed))
        }
    }

    @Test func aHookWithoutItsTimeoutIsBroughtUpToDate() throws {
        try withTempHome { _ in
            try on(true) {
                let bare: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": NotifyServer.permissionHookCommand]]]]]]
                try NotifyIntegration.writeJSON(bare, to: claude.configURL)
                #expect(!JSONHook.isCurrent(claude.hooks, in: try settings()))
                try claude.installNow()
                #expect(hooks(try settings(), "PermissionRequest").map { $0["timeout"] as? Int } == [600])
            }
        }
    }

    @Test func theHookIsOursUnderAnyEventAndOnlyOnOurPort() throws {
        let ours = try JSONHook.adding([("PermissionRequest", NotifyServer.permissionHookCommand)], to: [:])
        #expect(JSONHook.holdsAny(in: ours))
        #expect(JSONHook.removing(from: ours).isEmpty)
        // The test port's command is not Nunsseop's hook as far as a settings file goes.
        let other = try JSONHook.adding([("PermissionRequest", NotifyServer.permissionHookCommand(port: 50999))], to: [:])
        #expect(!JSONHook.holdsAny(in: other))
    }
}
