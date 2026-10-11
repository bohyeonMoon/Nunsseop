import Foundation
import Testing
@testable import Nunsseop

struct AgentHookEventTests {
    @Test func eventsAsTheCountReadsThem() {
        #expect(AgentHook.action(event: "UserPromptSubmit", type: nil) == .working)
        #expect(AgentHook.action(event: "Stop", type: nil) == .finished)
        #expect(AgentHook.action(event: "StopFailure", type: nil) == .finished)
        #expect(AgentHook.action(event: "SessionEnd", type: nil) == .remove)
        for type in ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"] {
            #expect(AgentHook.action(event: "Notification", type: type) == .needsInput)
        }
        #expect(AgentHook.action(event: "Notification", type: "idle_prompt") == .idle)
        #expect(AgentHook.action(event: "Notification", type: "elicitation_response") == .working)
        #expect(AgentHook.action(event: "Notification", type: "elicitation_complete") == .working)
        // Everything else says nothing about work.
        for type in ["auth_success", "agent_completed", "quota_low", "", nil] {
            #expect(AgentHook.action(event: "Notification", type: type) == nil)
        }
        #expect(AgentHook.action(event: "SubagentStop", type: nil) == nil)
        #expect(AgentHook.action(event: "PostToolUse", type: nil) == nil)
        // A type means something only on a Notification.
        #expect(AgentHook.action(event: "Stop", type: "idle_prompt") == .finished)
    }

    @Test func headersBecomeAnEvent() {
        let headers = ["x-session": "3f2a-B_9", "x-event": "Notification", "x-type": "permission_prompt",
                       "x-app": "com.apple.Terminal", "x-herdr": "1"]
        #expect(AgentHook.event(headers: headers)
                == AgentEvent(session: "3f2a-B_9", action: .needsInput, app: "com.apple.Terminal", inHerdr: true))
        let plain = AgentHook.event(headers: ["x-session": "s", "x-event": "Stop"])
        #expect(plain == AgentEvent(session: "s", action: .finished, app: nil, inHerdr: false))
        // The hook sends empty values for what it doesn't have.
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Stop", "x-app": "", "x-herdr": ""])?.app == nil)
    }

    @Test func headersOutsideTheWhitelistAreRefused() {
        let ok = ["x-session": "s", "x-event": "Stop"]
        #expect(AgentHook.event(headers: ok) != nil)
        #expect(AgentHook.event(headers: ["x-event": "Stop"]) == nil)
        #expect(AgentHook.event(headers: ["x-session": "", "x-event": "Stop"]) == nil)
        #expect(AgentHook.event(headers: ["x-session": "a\nb", "x-event": "Stop"]) == nil)
        #expect(AgentHook.event(headers: ["x-session": "a.b", "x-event": "Stop"]) == nil)
        #expect(AgentHook.event(headers: ["x-session": String(repeating: "a", count: 64), "x-event": "Stop"]) != nil)
        #expect(AgentHook.event(headers: ["x-session": String(repeating: "a", count: 65), "x-event": "Stop"]) == nil)
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Stop\n"]) == nil)
        #expect(AgentHook.event(headers: ok.merging(["x-app": "com.x\nevil"]) { $1 })?.app == nil)
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Nope"]) == nil)
    }

    @Test func aBackgroundSessionIsNeitherInHerdrNorInAnApp() {
        let headers = ["x-session": "s", "x-event": "UserPromptSubmit", "x-app": "com.apple.Terminal", "x-herdr": "1"]
        #expect(AgentHook.event(headers: headers.merging(["x-background": "1"]) { $1 })
                == AgentEvent(session: "s", action: .working, app: nil, inHerdr: false))
        #expect(AgentHook.event(headers: headers.merging(["x-background": ""]) { $1 })
                == AgentEvent(session: "s", action: .working, app: "com.apple.Terminal", inHerdr: true))
        #expect(NotifyServer.agentHookCommand.contains("X-Background: ${CLAUDE_JOB_DIR:+1}"))
    }

    @Test func aBackgroundNoticeHasNoApp() {
        let headers = ["x-app": "com.apple.Terminal"]
        #expect(NotifyServer.noticeApp(json: nil, headers: headers) == "com.apple.Terminal")
        #expect(NotifyServer.noticeApp(json: nil, headers: headers.merging(["x-background": ""]) { $1 }) == "com.apple.Terminal")
        #expect(NotifyServer.noticeApp(json: nil, headers: headers.merging(["x-background": "1"]) { $1 }) == nil)
        #expect(NotifyServer.noticeApp(json: ["app": "com.apple.Terminal"], headers: ["x-background": "1"]) == nil)
    }

    /// The notice hook as shipped, run in a shell with `curl` replaced by a stand-in that records its headers;
    /// the app the server would take from those headers.
    private func appOfNotice(inBackground: Bool) throws -> String? {
        let dir = URL(fileURLWithPath: "/tmp/nunsseop-test-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appendingPathComponent("Library/Application Support/Nunsseop")
        let bin = dir.appendingPathComponent("bin")
        for url in [support, bin] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try "secret-token".write(to: support.appendingPathComponent("notify-token"), atomically: true, encoding: .utf8)
        let curl = bin.appendingPathComponent("curl")
        try "#!/bin/sh\nfor arg; do printf '%s\\n' \"$arg\"; done > \"\(dir.path)/args\"\ncat >/dev/null\n"
            .write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", NotifyServer.hookCommand]
        var environment = ["HOME": dir.path, "PATH": "\(bin.path):/usr/bin:/bin", "__CFBundleIdentifier": "com.apple.Terminal"]
        if inBackground { environment["CLAUDE_JOB_DIR"] = "/tmp/jobs/1" }
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"message":"hi"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8).split(separator: "\n").map(String.init)
        var headers: [String: String] = [:]
        for arg in args where arg.contains(": ") {
            let parts = arg.split(separator: ":", maxSplits: 1)
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return NotifyServer.noticeApp(json: nil, headers: headers)
    }

    @Test func theNoticeHookNamesTheAppExceptInABackgroundSession() throws {
        #expect(NotifyServer.hookCommand.contains("X-Background: ${CLAUDE_JOB_DIR:+1}"))
        #expect(try appOfNotice(inBackground: false) == "com.apple.Terminal")
        #expect(try appOfNotice(inBackground: true) == nil)
    }

    @Test func subagentCallsAreDropped() {
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Stop", "x-subagent": "agent-1"]) == nil)
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Stop", "x-subagent": ""]) != nil)
    }

    @Test func hookCommandSendsOnlyIdsAndNames() {
        let command = NotifyServer.agentHookCommand
        #expect(command.contains("127.0.0.1:\(NotifyServer.port)/agent"))
        #expect(command.contains("-m 1") && command.contains("--connect-timeout 1"))
        #expect(command.contains(">/dev/null 2>&1 || true"))
        for field in ["session_id", "hook_event_name", "notification_type", "agent_id"] { #expect(command.contains(field)) }
        for private_ in ["prompt", "last_assistant_message", "cwd", "transcript_path", "--data-binary"] {
            #expect(!command.contains(private_))
        }
    }
}

@MainActor
struct AgentHooksTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func make(on: Bool = true, herdr: Bool = false, frontmost: String? = nil)
        -> (hooks: AgentHooks, board: AgentBoard) {
        let board = AgentBoard()
        return (AgentHooks(board: board, isOn: { on }, watchesHerdr: { herdr }, frontmostApp: { frontmost }), board)
    }

    private func event(_ session: String, _ action: AgentAction, app: String? = nil, inHerdr: Bool = false) -> AgentEvent {
        AgentEvent(session: session, action: action, app: app, inHerdr: inHerdr)
    }

    @Test func workingExpiresAndEveryEventRefreshesIt() {
        let (hooks, board) = make()
        hooks.apply(event("a", .working), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1))
        board.recount(now: start.addingTimeInterval(19 * 60))
        #expect(board.counts == AgentBoard.Counts(working: 1))
        board.recount(now: start.addingTimeInterval(20 * 60 + 1))
        #expect(board.counts.isEmpty)

        hooks.apply(event("a", .working), now: start)
        hooks.apply(event("a", .working), now: start.addingTimeInterval(15 * 60))
        board.recount(now: start.addingTimeInterval(30 * 60))
        #expect(board.counts == AgentBoard.Counts(working: 1))
        board.recount(now: start.addingTimeInterval(36 * 60))
        #expect(board.counts.isEmpty)
    }

    @Test func needingInputWaits() {
        let (hooks, board) = make()
        hooks.apply(event("a", .working), now: start)
        hooks.apply(event("a", .needsInput), now: start.addingTimeInterval(5))
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        board.recount(now: start.addingTimeInterval(21 * 60))
        #expect(board.counts.isEmpty)
        // Answered: the next event of the turn works again.
        hooks.apply(event("a", .needsInput), now: start)
        hooks.apply(event("a", .working), now: start.addingTimeInterval(5))
        #expect(board.counts == AgentBoard.Counts(working: 1))
    }

    @Test func finishedWaitsForTenMinutes() {
        let (hooks, board) = make()
        hooks.apply(event("a", .working), now: start)
        hooks.apply(event("a", .finished, app: "com.apple.Terminal"), now: start.addingTimeInterval(30))
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        board.recount(now: start.addingTimeInterval(30 + 9 * 60))
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        board.recount(now: start.addingTimeInterval(30 + 10 * 60 + 1))
        #expect(board.counts.isEmpty)
        // The next prompt takes the hand away.
        hooks.apply(event("a", .finished), now: start)
        hooks.apply(event("a", .working), now: start.addingTimeInterval(60))
        #expect(board.counts == AgentBoard.Counts(working: 1))
    }

    @Test func finishedInTheFrontAppIsAlreadySeen() {
        let (hooks, board) = make(frontmost: "com.apple.Terminal")
        hooks.apply(event("a", .working, app: "com.apple.Terminal"), now: start)
        hooks.apply(event("a", .finished, app: "com.apple.Terminal"), now: start)
        #expect(board.counts.isEmpty)
        hooks.apply(event("b", .finished, app: "com.mitchellh.ghostty"), now: start)
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        // No app known: can't tell, so it waits.
        hooks.apply(event("c", .finished), now: start)
        #expect(board.counts == AgentBoard.Counts(waiting: 2))
    }

    @Test func idleClearsEverythingButAFinishedHand() {
        let (hooks, board) = make()
        hooks.apply(event("a", .working), now: start)
        hooks.apply(event("a", .idle), now: start)
        #expect(board.counts.isEmpty)
        hooks.apply(event("a", .finished), now: start)
        hooks.apply(event("a", .idle), now: start)
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        // Esc or a rejected permission sends no Stop, but the idle prompt means nothing is asked any more.
        hooks.apply(event("b", .needsInput), now: start)
        #expect(board.counts == AgentBoard.Counts(waiting: 2))
        hooks.apply(event("b", .idle), now: start)
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        // An idle prompt for a session never heard of adds nothing.
        hooks.apply(event("c", .idle), now: start)
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
    }

    @Test func endedSessionsGoAndEachCountsOnce() {
        let (hooks, board) = make()
        hooks.apply(event("a", .working), now: start)
        hooks.apply(event("b", .working), now: start)
        hooks.apply(event("b", .working), now: start)
        hooks.apply(event("c", .needsInput), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 2, waiting: 1))
        hooks.apply(event("a", .remove), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
        hooks.apply(event("zzz", .remove), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
    }

    @Test func herdrPanesAreLeftToHerdr() {
        let (watching, watchingBoard) = make(herdr: true)
        watching.apply(event("a", .working, inHerdr: true), now: start)
        #expect(watchingBoard.counts.isEmpty)
        watching.apply(event("b", .working), now: start)
        #expect(watchingBoard.counts == AgentBoard.Counts(working: 1))

        let (alone, aloneBoard) = make(herdr: false)
        alone.apply(event("a", .working, inHerdr: true), now: start)
        #expect(aloneBoard.counts == AgentBoard.Counts(working: 1))
    }

    @Test func nothingCountsWhileTheCountIsHidden() {
        let (hooks, board) = make(on: false)
        hooks.apply(event("a", .working), now: start)
        #expect(board.counts.isEmpty)
    }

    @Test func resetForgetsEverySession() {
        let (hooks, board) = make()
        hooks.apply(event("a", .working), now: start)
        hooks.reset()
        #expect(board.counts.isEmpty)
        // Not a stale entry coming back with the next event.
        hooks.apply(event("b", .working), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1))
    }

    @Test func hooksAreASourceOfTheirOwn() {
        let (hooks, board) = make()
        board.replace(source: "herdr:a", with: ["p": .working])
        hooks.apply(event("a", .working), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 2))
        hooks.reset()
        #expect(board.counts == AgentBoard.Counts(working: 1))
    }

    @Test func comingToTheAppClearsOnlyItsFinishedHands() {
        let (hooks, board) = make(frontmost: "com.apple.Terminal")
        // activated() publishes at the real time, so the events are timed from it too.
        let now = Date.now
        hooks.apply(event("a", .finished, app: "com.mitchellh.ghostty"), now: now)
        hooks.apply(event("b", .needsInput, app: "com.mitchellh.ghostty"), now: now)
        hooks.apply(event("c", .finished), now: now)
        hooks.apply(event("d", .working, app: "com.mitchellh.ghostty"), now: now)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 3))

        hooks.activated("com.apple.Terminal")
        hooks.activated(nil)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 3))

        // The finished hand in ghostty is seen; the permission request and the working session stay.
        hooks.activated("com.mitchellh.ghostty")
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 2))
        hooks.activated("com.mitchellh.ghostty")
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 2))

        // A finished session with no app (a background one) can't be seen by coming to any app; it times out.
        board.recount(now: now.addingTimeInterval(Herdr.doneWindow - 1))
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 2))
        board.recount(now: now.addingTimeInterval(Herdr.doneWindow + 1))
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
        board.recount(now: now.addingTimeInterval(AgentHooks.activeWindow + 1))
        #expect(board.counts.isEmpty)
    }
}
