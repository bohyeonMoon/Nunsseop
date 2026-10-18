import Foundation
import Testing
@testable import Nunsseop

/// Gemini CLI's hooks as the docs describe them (https://geminicli.com/docs/hooks/reference/): the event JSON has `session_id`,
/// `hook_event_name` and, on a `Notification`, `notification_type`; `timeout` is in milliseconds.
struct GeminiSessionTests {
    private let command = NotifyServer.agentHookCommand(for: .gemini)
    private let session = "6f1c2b7e-0d9a-4c8e-9a3b-1d2e3f4a5b6c"

    private func payload(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": session, "transcript_path": "/Users/me/.gemini/tmp/x/chats/session.json", "cwd": "/Users/me/secret-project",
         "hook_event_name": event, "timestamp": "2026-10-17T09:00:00.000Z"].merging(extra) { $1 }
    }

    @Test func eachEventBecomesTheBoardStateTheDocsImply() throws {
        let cases: [(String, [String: Any], AgentAction)] = [
            ("SessionStart", ["source": "startup"], .opened),
            ("BeforeAgent", ["prompt": "fix the bug"], .working),
            ("Notification", ["notification_type": "ToolPermission", "message": "Needs permission", "details": [:]], .needsInput),
            ("AfterAgent", ["prompt": "fix the bug", "prompt_response": "done", "stop_hook_active": false], .finished),
            ("SessionEnd", ["reason": "exit"], .remove),
        ]
        for (name, extra, action) in cases {
            let (event, run) = try ToolHook.run(command, payload(name, extra))
            #expect(event == AgentEvent(session: session, action: action, app: "com.mitchellh.ghostty", agent: .gemini, pid: getpid()), "\(name)")
            // Only ids and names leave: not the prompt, the reply, the folder or the transcript's path.
            #expect(!run.args.joined().contains("secret-project") && !run.args.joined().contains("fix the bug") && run.body.isEmpty, "\(name)")
            #expect(run.stdout.isEmpty && run.status == 0, "\(name)")
        }
    }

    @Test func aNotificationOfAnotherKindSaysNothingAboutWork() throws {
        let (event, run) = try ToolHook.run(command, payload("Notification", ["notification_type": "SomethingNew"]))
        #expect(event == nil && run.curlCalls == 1)
    }

    @MainActor
    @Test func aTurnGoesFromWorkingToAskingToAFinishedHand() throws {
        let board = AgentBoard()
        let hooks = AgentHooks(board: board, agent: .gemini, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }, isAlive: { _ in true })
        let now = Date.now
        for (name, extra) in [("SessionStart", [:]), ("BeforeAgent", [:]), ("Notification", ["notification_type": "ToolPermission"])] as [(String, [String: Any])] {
            let (event, _) = try ToolHook.run(command, payload(name, extra), environment: [:])
            hooks.apply(try #require(event), now: now)
        }
        var row = try #require(board.entries(now: now).first)
        #expect(row.agent.state == .waiting && !row.agent.finished && row.agent.tool == "gemini")
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        hooks.apply(try #require(try ToolHook.run(command, payload("AfterAgent"), environment: [:]).event), now: now.addingTimeInterval(5))
        row = try #require(board.entries(now: now.addingTimeInterval(5)).first)
        #expect(row.agent.state == .waiting && row.agent.finished)
        #expect(AgentRow.toolName(row.agent.tool) == "Gemini CLI")
        hooks.apply(try #require(try ToolHook.run(command, payload("SessionEnd"), environment: [:]).event), now: now.addingTimeInterval(9))
        #expect(board.entries(now: now.addingTimeInterval(9)).isEmpty)
    }

    @Test func aClosedNunsseopCostsGeminiNothing() throws {
        for curlExit in [Int32(7), 28] {
            let (_, run) = try ToolHook.run(command, payload("BeforeAgent"), curlExit: curlExit)
            #expect(run.status == 0 && run.stdout.isEmpty)
        }
    }

    @Test func connectingKeepsOtherHooksAndSettingsAndBacksTheFileUp() throws {
        try withTempHome { _ in
            let tool = NotifyIntegration.gemini
            let seed = #"{"theme":"dark","hooks":{"AfterAgent":[{"matcher":"*","hooks":[{"name":"mine","type":"command","command":"mine.sh","timeout":5000}]}]}}"#
            try FileManager.default.createDirectory(at: tool.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(seed.utf8).write(to: tool.configURL)
            try tool.install()

            let settings = try NotifyIntegration.loadJSON(at: tool.configURL)
            #expect(JSONHook.isCurrent(tool.hooks, in: settings) && tool.isInstalled && settings["theme"] as? String == "dark")
            let after = ((settings["hooks"] as? [String: Any])?["AfterAgent"] as? [[String: Any]]) ?? []
            #expect(after.count == 2 && (after[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "mine.sh")
            #expect(try Data(contentsOf: tool.configURL.appendingPathExtension("nunsseop-backup")) == Data(seed.utf8))

            try tool.uninstall()
            let removed = try NotifyIntegration.loadJSON(at: tool.configURL)
            #expect(!tool.isInstalled && !JSONHook.holdsAny(in: removed))
            let kept = ((removed["hooks"] as? [String: Any])?["AfterAgent"] as? [[String: Any]]) ?? []
            #expect(kept.count == 1 && (kept[0]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 5000)
            #expect((removed["hooks"] as? [String: Any])?.keys.sorted() == ["AfterAgent"])
        }
    }

    @Test func aConnectionFromBeforeSessionsAreReportedGainsTheHooksAtLaunch() throws {
        try withTempHome { _ in
            let tool = NotifyIntegration.gemini
            try NotifyIntegration.writeJSON(JSONHook.adding(NotifyServer.hookCommand(title: "Gemini CLI"), to: [:]), to: tool.configURL)
            let before = try NotifyIntegration.loadJSON(at: tool.configURL)
            #expect(tool.isInstalled && !JSONHook.isCurrent(tool.hooks, in: before))
            NotifyIntegration.updateConnectedNow()
            let after = try NotifyIntegration.loadJSON(at: tool.configURL)
            #expect(JSONHook.isCurrent(tool.hooks, in: after))
            #expect(NotifyIntegration.reportingSessions.contains(.gemini))
        }
    }
}
