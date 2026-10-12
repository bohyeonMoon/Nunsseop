import Foundation
import Testing
@testable import Nunsseop

/// The PreToolUse hook for questions in Claude Code's settings, against a scratch home folder.
struct PermissionQuestionInstallTests {
    private let claude = NotifyIntegration.claudeCode
    private let command = NotifyServer.permissionHookCommand

    private func settings() throws -> [String: Any] { try NotifyIntegration.loadJSON(at: claude.configURL) }

    private func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    private func ours(_ settings: [String: Any]) -> [[String: Any]] {
        groups(settings, "PreToolUse").filter { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == command }
        }
    }

    private func on<T>(_ answers: Bool, _ body: () throws -> T) rethrows -> T {
        try NotifyIntegration.$permissionPromptsOverride.withValue(answers, operation: body)
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(at: claude.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: claude.configURL)
    }

    private let mine = #"""
        {"model":"opus","hooks":{"PreToolUse":[
          {"matcher":"Bash","hooks":[{"type":"command","command":"mine-bash.sh","timeout":5}]},
          {"hooks":[{"type":"command","command":"mine-all.sh"}]},
          {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"mine-ask.sh"}]}]}}
        """#

    private func theirs(_ settings: [String: Any]) -> [[String: Any]] {
        groups(settings, "PreToolUse").filter { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).allSatisfy { ($0["command"] as? String)?.hasSuffix(".sh") == true }
        }
    }

    @Test func connectingAddsTheHookUnderPreToolUseForTheQuestionToolOnly() throws {
        try withTempHome { _ in
            try on(true) {
                try claude.installNow()
                let added = ours(try settings())
                #expect(added.count == 1)
                #expect(added[0]["matcher"] as? String == "AskUserQuestion")
                let hook = try #require((added[0]["hooks"] as? [[String: Any]])?.first)
                #expect(hook["command"] as? String == command && hook["timeout"] as? Int == 600 && hook["type"] as? String == "command")
                #expect(JSONHook.isCurrent(claude.hooks, in: try settings()))
                // The approvals keep their hook, which has no matcher.
                #expect(groups(try settings(), "PermissionRequest").allSatisfy { $0["matcher"] == nil })
            }
        }
    }

    @Test func theTableHoldsTheHookOnlyWhileTheSettingIsOnAndNoOtherToolGetsIt() {
        let events = { (answers: Bool) in self.on(answers) { self.claude.hooks.map(\.event).filter { $0 == "PreToolUse" } } }
        #expect(events(true) == ["PreToolUse"] && events(false).isEmpty)
        for tool in [NotifyIntegration.codex, .gemini, .openCode] {
            #expect(on(true) { tool.hooks.map(\.event).contains("PreToolUse") } == false)
        }
    }

    @Test func theHookIsNeverInAGroupWithoutTheMatcher() throws {
        let table: JSONHook.Table = [("PreToolUse", command)]
        let added = try JSONHook.adding(table, to: [:])
        #expect(groups(added, "PreToolUse").map { $0["matcher"] as? String } == ["AskUserQuestion"])
        // Not for the other events, and not for a command of someone else's under the same event.
        let others = try JSONHook.adding([("PermissionRequest", command), ("PreToolUse", "mine.sh")], to: [:])
        #expect(groups(others, "PermissionRequest").allSatisfy { $0["matcher"] == nil })
        #expect(groups(others, "PreToolUse").allSatisfy { $0["matcher"] == nil })
    }

    @Test func aConnectionFromBeforeQuestionsGetsTheHookAtTheNextRefresh() throws {
        try withTempHome { _ in
            let before = on(true) { claude.hooks }.filter { $0.event != "PreToolUse" }
            try NotifyIntegration.writeJSON(JSONHook.adding(before, to: ["model": "opus"]), to: claude.configURL)
            let stale = try settings()
            try on(true) {
                #expect(claude.isInstalled && !JSONHook.isCurrent(claude.hooks, in: stale))
                NotifyIntegration.updateConnectedNow()
                let now = try settings()
                #expect(ours(now).count == 1)
                #expect(JSONHook.isCurrent(claude.hooks, in: now))
                #expect(now["model"] as? String == "opus")
                // And once it is current nothing is written again.
                let again = try JSONHook.updating(claude.hooks, in: now)
                #expect(again == nil)
            }
        }
    }

    @Test func turningTheSettingOffTakesTheHookAwayAndOnPutsItBack() throws {
        try withTempHome { _ in
            try on(true) { try claude.installNow() }
            on(false) { NotifyIntegration.updateConnectedNow() }
            let without = try settings()
            #expect((without["hooks"] as? [String: Any])?["PreToolUse"] == nil)
            #expect(claude.isInstalled && groups(without, "PermissionRequest").isEmpty)
            on(false) { #expect(JSONHook.isCurrent(claude.hooks, in: without)) }
            on(true) { NotifyIntegration.updateConnectedNow() }
            let now = try settings()
            #expect(ours(now).count == 1 && groups(now, "PermissionRequest").count == 1)
        }
    }

    @Test func otherToolsGroupsUnderPreToolUseSurviveEveryChange() throws {
        try withTempHome { _ in
            try write(mine)
            let original = theirs(try settings())
            #expect(original.count == 3)
            func untouched() throws -> Bool {
                let now = theirs(try settings())
                return now.count == original.count && zip(now, original).allSatisfy { NSDictionary(dictionary: $0).isEqual(to: $1) }
            }
            try on(true) { try claude.installNow() }
            #expect(try untouched() && ours(try settings()).count == 1)
            on(false) { NotifyIntegration.updateConnectedNow() }
            #expect(try untouched() && ours(try settings()).isEmpty)
            on(true) { NotifyIntegration.updateConnectedNow() }
            #expect(try untouched() && ours(try settings()).count == 1)
            try claude.uninstallNow()
            #expect(try untouched() && ours(try settings()).isEmpty && !JSONHook.holdsAny(in: try settings()))
            #expect(try settings()["model"] as? String == "opus")
        }
    }

    @Test func aHookOfOursWithoutItsMatcherOrWithAnotherIsBroughtUpToDate() throws {
        for (name, matcher) in [("no matcher", nil), ("another matcher", "Bash"), ("an empty matcher", "")] as [(String, String?)] {
            try withTempHome { _ in
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 600]]]
                group["matcher"] = matcher
                let stale: [String: Any] = ["hooks": ["PreToolUse": [group],
                                                      "Notification": [["hooks": [["type": "command", "command": NotifyServer.hookCommand(title: "Claude Code")]]]]]]
                try NotifyIntegration.writeJSON(stale, to: claude.configURL)
                try on(true) {
                    #expect(!JSONHook.isCurrent(claude.hooks, in: try settings()), Comment(rawValue: name))
                    NotifyIntegration.updateConnectedNow()
                    let added = ours(try settings())
                    #expect(added.count == 1 && added[0]["matcher"] as? String == "AskUserQuestion", Comment(rawValue: name))
                    #expect(JSONHook.isCurrent(claude.hooks, in: try settings()), Comment(rawValue: name))
                }
            }
        }
    }

    @Test func ourHookInsideAGroupOfSomeoneElsesLeavesTheirsWhereItWas() throws {
        try withTempHome { _ in
            let shared: [String: Any] = ["hooks": [
                "Notification": [["hooks": [["type": "command", "command": NotifyServer.hookCommand(title: "Claude Code")]]]],
                "PreToolUse": [["matcher": "Write", "hooks": [["type": "command", "command": "mine.sh"],
                                                               ["type": "command", "command": command, "timeout": 600]]]]]]
            try NotifyIntegration.writeJSON(shared, to: claude.configURL)
            try on(true) {
                NotifyIntegration.updateConnectedNow()
                let all = groups(try settings(), "PreToolUse")
                let mineGroup = try #require(all.first { $0["matcher"] as? String == "Write" })
                #expect((mineGroup["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } == ["mine.sh"])
                #expect(ours(try settings()).map { $0["matcher"] as? String } == ["AskUserQuestion"])
            }
        }
    }
}
