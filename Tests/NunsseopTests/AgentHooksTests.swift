import Foundation
import Testing
@testable import Nunsseop

struct AgentHookEventTests {
    @Test func eventsAsTheCountReadsThem() {
        #expect(AgentHook.action(event: "UserPromptSubmit", type: nil) == .working)
        #expect(AgentHook.action(event: "Stop", type: nil) == .finished)
        #expect(AgentHook.action(event: "StopFailure", type: nil) == .finished)
        #expect(AgentHook.action(event: "SessionEnd", type: nil) == .remove)
        #expect(AgentHook.action(event: "SessionStart", type: nil) == .opened)
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

    @Test func theProcessIdComesOnlyFromPlainDigits() {
        let pid = { (value: String?) -> Int32? in
            AgentHook.event(headers: ["x-session": "s", "x-event": "Stop"].merging(value.map { ["x-pid": $0] } ?? [:]) { $1 })?.pid
        }
        #expect(pid("4242") == 4242 && pid("2") == 2 && pid("0042") == 42)
        #expect(pid("2147483647") == Int32.max)
        // Nothing, init, zero, too big, too long, signs, spaces, other digits and text are no process id.
        for bad in [nil, "", "0", "1", "00001", "2147483648", "9999999999", "12345678901", "-5", "+5", " 5", "5 ", "5\n", "1e3",
                    "12a", "０５", "٣٣", "0x10"] as [String?] {
            #expect(pid(bad) == nil, "\(bad ?? "nil")")
        }
        // A bad one doesn't refuse the event.
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Stop", "x-pid": "junk"]) != nil)
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Stop", "x-pid": "77", "x-agent": "codex"])?.pid == 77)
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Stop", "x-pid": "77", "x-background": "1"])?.pid == nil)
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

    @Test func subagentCallsAreDropped() {
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Stop", "x-subagent": "agent-1"]) == nil)
        #expect(AgentHook.event(headers: ["x-session": "s", "x-event": "Stop", "x-subagent": ""]) != nil)
    }

    @Test func codexEventsAsTheCountReadsThem() {
        #expect(AgentHook.action(event: "UserPromptSubmit", type: nil) == .working)
        #expect(AgentHook.action(event: "PermissionRequest", type: nil) == .needsInput)
        #expect(AgentHook.action(event: "Stop", type: nil) == .finished)
        #expect(AgentHook.action(event: "Interrupt", type: nil) == .idle)
        #expect(AgentHook.action(event: "SessionEnd", type: nil) == .remove)
        // The rest of Codex's events say nothing about the turn as a whole.
        for event in ["PreToolUse", "PostToolUse", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop"] {
            #expect(AgentHook.action(event: event, type: nil) == nil, "\(event)")
        }
    }

    @Test func theAgentHeaderTellsCodexFromClaudeCode() {
        let base = ["x-session": "019e-abc", "x-event": "PermissionRequest", "x-app": "com.apple.Terminal"]
        #expect(AgentHook.event(headers: base.merging(["x-agent": "codex"]) { $1 })
                == AgentEvent(session: "019e-abc", action: .needsInput, app: "com.apple.Terminal", inHerdr: false, agent: .codex))
        // Claude Code's hook has no such header, and an empty or named one means the same.
        for agent in [nil, "", "claude"] {
            let headers = agent.map { base.merging(["x-agent": $0]) { $1 } } ?? base
            #expect(AgentHook.event(headers: headers)?.agent == .claude, "\(agent ?? "nil")")
        }
        // Whatever else is refused, so a stray value can't open a source of its own.
        for agent in ["gemini", "Codex", "codex\n", "codex ", String(repeating: "a", count: 65)] {
            #expect(AgentHook.event(headers: base.merging(["x-agent": agent]) { $1 }) == nil, "\(agent)")
        }
    }

    @Test func codexSubagentCallsAreDropped() {
        let headers = ["x-session": "s", "x-event": "PermissionRequest", "x-agent": "codex"]
        #expect(AgentHook.event(headers: headers) != nil)
        #expect(AgentHook.event(headers: headers.merging(["x-subagent": "worker-1"]) { $1 }) == nil)
    }

    @Test func codexHookCommandNamesItsAgentAndSendsOnlyIdsAndNames() {
        let command = NotifyServer.agentHookCommand(for: .codex)
        #expect(command.contains("127.0.0.1:\(NotifyServer.port)/agent"))
        #expect(command.contains("X-Agent: codex"))
        #expect(command.contains("-m 1") && command.contains("--connect-timeout 1") && command.contains(">/dev/null 2>&1 || true"))
        for field in ["session_id", "hook_event_name", "agent_id"] { #expect(command.contains(field)) }
        for private_ in ["prompt", "last_assistant_message", "tool_input", "cwd", "transcript_path", "--data-binary"] {
            #expect(!command.contains(private_))
        }
        // Claude Code's command is the one installed so far, and stays as it was.
        #expect(NotifyServer.agentHookCommand == NotifyServer.agentHookCommand(for: .claude))
        #expect(!NotifyServer.agentHookCommand.contains("X-Agent"))
        // Its process is reported as Claude Code's is (assumed to be `$PPID` of the hook, as for Claude Code), after the common headers.
        #expect(command.contains(#"-H "X-Pid: $PPID" -H 'X-Agent: codex'"#))
    }

    /// Codex asks to trust a hook again when its command changes, so this text is pinned: a change is a decision.
    @Test func codexHookCommandIsPinned() {
        let pinned = #"in=$(cat); k() { printf '%s' "$in" | plutil -extract "$1" raw -o - - 2>/dev/null | tr -cd 'A-Za-z0-9_.-' | cut -c1-64; }; "#
            + #"curl -s -m 1 --connect-timeout 1 -X POST http://127.0.0.1:47750/agent -d '' "#
            + #"-H @"$HOME/Library/Application Support/Nunsseop/notify-auth" "#
            + #"-H "X-Session: $(k session_id)" -H "X-Event: $(k hook_event_name)" -H "X-Type: $(k notification_type)" "#
            + #"-H "X-Subagent: $(k agent_id)" -H "X-App: $__CFBundleIdentifier" -H "X-Herdr: ${HERDR_PANE_ID:+1}" "#
            + #"-H "X-Muxy: ${MUXY_SESSION_ID}" -H "X-Cmux: ${CMUX_SURFACE_ID}" "#
            + #"-H "X-Mux: ${TMUX:+1}${ZELLIJ:+1}${STY:+1}" "#
            + #"-H "X-Background: ${CLAUDE_JOB_DIR:+1}" -H "X-Pid: $PPID" -H 'X-Agent: codex' >/dev/null 2>&1 || true"#
        #expect(NotifyServer.port == 47750)
        #expect(NotifyServer.agentHookCommand(for: .codex) == pinned)
        #expect(NotifyServer.agentHookCommand(for: .codex, port: 47750) == pinned)
    }

    @Test func claudeCodesHookSendsItsProcessAndPrintsNothing() {
        let command = NotifyServer.agentHookCommand(for: .claude)
        #expect(command.contains(#"-H "X-Pid: $PPID""#))
        #expect(command.hasSuffix(">/dev/null 2>&1 || true"))
        #expect(!command.contains("X-Agent"))
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

    private func make(on: Bool = true, herdr: Bool = false, frontmost: String? = nil, isAlive: @escaping (Int32) -> Bool = { _ in true })
        -> (hooks: AgentHooks, board: AgentBoard) {
        let board = AgentBoard()
        return (AgentHooks(board: board, isOn: { on }, watchesHerdr: { herdr }, frontmostApp: { frontmost }, isAlive: isAlive), board)
    }

    private func event(_ session: String, _ action: AgentAction, app: String? = nil, inHerdr: Bool = false, pid: Int32? = nil) -> AgentEvent {
        AgentEvent(session: session, action: action, app: app, inHerdr: inHerdr, pid: pid)
    }

    private func listed(_ board: AgentBoard, at now: Date, _ id: String? = nil) -> [AgentBoard.Entry] {
        board.entries(now: now).filter { id == nil || $0.id == id }.sorted { $0.id < $1.id }
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

    @Test func codexSessionsAreASourceOfTheirOwn() {
        let board = AgentBoard()
        let claude = AgentHooks(board: board, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil })
        let codex = AgentHooks(board: board, agent: .codex, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil })
        #expect(claude.source == "hooks:claude" && codex.source == "hooks:codex")
        // The same session id from both tools is two sessions.
        claude.apply(event("same", .working), now: start)
        codex.apply(event("same", .needsInput), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
        // One's end, idle or reset doesn't touch the other.
        codex.apply(event("same", .remove), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1))
        codex.apply(event("same", .working), now: start)
        claude.apply(event("same", .idle), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1))
        codex.reset()
        #expect(board.counts.isEmpty)
    }

    @Test func codexFollowsTheSameRulesAsClaudeCode() {
        let board = AgentBoard()
        let codex = AgentHooks(board: board, agent: .codex, isOn: { true }, watchesHerdr: { true },
                               frontmostApp: { "com.apple.Terminal" })
        // A herdr pane is herdr's; a turn finished in the front app was seen; one elsewhere waits.
        codex.apply(event("h", .working, inHerdr: true), now: start)
        #expect(board.counts.isEmpty)
        codex.apply(event("a", .working, app: "com.apple.Terminal"), now: start)
        codex.apply(event("a", .finished, app: "com.apple.Terminal"), now: start)
        #expect(board.counts.isEmpty)
        codex.apply(event("b", .working, app: "com.mitchellh.ghostty"), now: start)
        codex.apply(event("b", .needsInput, app: "com.mitchellh.ghostty"), now: start.addingTimeInterval(1))
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        // An interrupt clears what was asked, and a finished hand stays.
        codex.apply(event("b", .idle, app: "com.mitchellh.ghostty"), now: start.addingTimeInterval(2))
        #expect(board.counts.isEmpty)
        codex.apply(event("c", .finished, app: "com.mitchellh.ghostty"), now: start)
        codex.apply(event("c", .idle, app: "com.mitchellh.ghostty"), now: start)
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
    }

    @Test func eachToolsEventsGoToItsOwnHooks() {
        let board = AgentBoard()
        let tools = ToolHooks(claude: AgentHooks(board: board, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }),
                              codex: AgentHooks(board: board, agent: .codex, isOn: { true }, watchesHerdr: { false },
                                                frontmostApp: { nil }))
        tools.apply(AgentEvent(session: "x", action: .working, agent: .codex), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1))
        // The same id from Claude Code is another session, and ending it leaves Codex's.
        tools.apply(event("x", .needsInput), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
        tools.apply(event("x", .remove), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1))
        tools.apply(AgentEvent(session: "x", action: .remove, agent: .codex), now: start)
        #expect(board.counts.isEmpty)
    }

    @Test func hidingTheCountClearsBothToolsSessions() {
        let board = AgentBoard()
        let tools = ToolHooks(claude: AgentHooks(board: board, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }),
                              codex: AgentHooks(board: board, agent: .codex, isOn: { true }, watchesHerdr: { false },
                                                frontmostApp: { nil }))
        tools.apply(event("a", .working), now: start)
        tools.apply(AgentEvent(session: "b", action: .needsInput, agent: .codex), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
        tools.reset()
        #expect(board.counts.isEmpty)
        // Nothing comes back with the next event.
        tools.apply(AgentEvent(session: "c", action: .working, agent: .codex), now: start)
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

    // MARK: Idle sessions

    @Test func workingTurnsIdleAfterTheActiveWindowButStaysListedForThreeHours() throws {
        let (hooks, board) = make()
        hooks.apply(event("a", .working), now: start)
        let working = try #require(listed(board, at: start).first)
        #expect(working.agent.state == .working && working.agent.since == start)
        let almost = start.addingTimeInterval(AgentHooks.activeWindow - 1)
        #expect(listed(board, at: almost).first?.agent.state == .working)

        let idleAt = start.addingTimeInterval(AgentHooks.activeWindow)
        let idle = try #require(listed(board, at: idleAt).first)
        #expect(idle.agent.state == .idle && idle.agent.since == idleAt && !idle.agent.finished)
        board.recount(now: idleAt)
        #expect(board.counts.isEmpty)
        #expect(listed(board, at: start.addingTimeInterval(AgentBoard.recentWindow - 1)).count == 1)
        #expect(listed(board, at: start.addingTimeInterval(AgentBoard.recentWindow)).isEmpty)
    }

    @Test func askingForInputTurnsIdleAfterTheActiveWindowToo() throws {
        let (hooks, board) = make()
        hooks.apply(event("a", .needsInput), now: start)
        #expect(listed(board, at: start).first?.agent.state == .waiting)
        let idle = try #require(listed(board, at: start.addingTimeInterval(AgentHooks.activeWindow + 1)).first)
        #expect(idle.agent.state == .idle && idle.agent.since == start.addingTimeInterval(AgentHooks.activeWindow))
    }

    @Test func aFinishedHandWaitsThenSitsIdle() throws {
        let (hooks, board) = make()
        hooks.apply(event("a", .finished, app: "com.apple.Terminal"), now: start)
        let hand = try #require(listed(board, at: start).first)
        #expect(hand.agent.state == .waiting && hand.agent.finished && hand.agent.idleFrom == start.addingTimeInterval(Herdr.doneWindow))
        let later = start.addingTimeInterval(Herdr.doneWindow)
        let idle = try #require(listed(board, at: later).first)
        #expect(idle.agent.state == .idle && !idle.agent.finished && idle.agent.since == later)
        board.recount(now: later)
        #expect(board.counts.isEmpty)
    }

    @Test func everyEventPushesTheExpiryToThreeHoursAfterIt() {
        let (hooks, board) = make()
        hooks.apply(event("a", .working), now: start)
        hooks.apply(event("a", .idle), now: start.addingTimeInterval(3_600))
        #expect(listed(board, at: start.addingTimeInterval(3_600 + AgentBoard.recentWindow - 1)).count == 1)
        #expect(listed(board, at: start.addingTimeInterval(3_600 + AgentBoard.recentWindow)).isEmpty)
        // An event after the expiry finds the old entry gone.
        hooks.apply(event("b", .working), now: start.addingTimeInterval(3_600 + AgentBoard.recentWindow + 1))
        #expect(listed(board, at: start.addingTimeInterval(3_600 + AgentBoard.recentWindow + 1)).map(\.id) == ["b"])
    }

    @Test func finishedInTheFrontAppIsIdleNotGone() throws {
        let (hooks, board) = make(frontmost: "com.apple.Terminal")
        hooks.apply(event("a", .working, app: "com.apple.Terminal"), now: start)
        hooks.apply(event("a", .finished, app: "com.apple.Terminal"), now: start.addingTimeInterval(30))
        let seen = try #require(listed(board, at: start.addingTimeInterval(30)).first)
        #expect(seen.agent.state == .idle && seen.agent.since == start.addingTimeInterval(30) && !seen.agent.finished)
        #expect(seen.agent.app == "com.apple.Terminal" && board.counts.isEmpty)
        // Idle already: another finish keeps when it became idle.
        hooks.apply(event("a", .finished, app: "com.apple.Terminal"), now: start.addingTimeInterval(90))
        #expect(listed(board, at: start.addingTimeInterval(90)).first?.agent.since == start.addingTimeInterval(30))
    }

    @Test func anIdleEventMakesAnythingButAFinishedHandIdle() throws {
        let (hooks, board) = make()
        hooks.apply(event("w", .working), now: start)
        hooks.apply(event("q", .needsInput), now: start)
        hooks.apply(event("f", .finished), now: start)
        for id in ["w", "q", "f", "new"] { hooks.apply(event(id, .idle), now: start.addingTimeInterval(60)) }
        let at = start.addingTimeInterval(60)
        let states = Dictionary(uniqueKeysWithValues: listed(board, at: at).map { ($0.id, $0.agent) })
        #expect(states["w"]?.state == .idle && states["w"]?.since == at)
        #expect(states["q"]?.state == .idle && states["q"]?.since == at)
        // A session never heard of is added as idle.
        #expect(states["new"]?.state == .idle && states["new"]?.since == at)
        // The finished hand stays as it was.
        #expect(states["f"]?.state == .waiting && states["f"]?.finished == true && states["f"]?.since == start)
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        // Idle again keeps since.
        hooks.apply(event("w", .idle), now: start.addingTimeInterval(120))
        #expect(listed(board, at: at, "w").first?.agent.since == at)
    }

    @Test func openingASessionListsItIdleOnlyWhenNew() throws {
        let (hooks, board) = make()
        hooks.apply(event("a", .opened, app: "com.apple.Terminal", pid: 500), now: start)
        let opened = try #require(listed(board, at: start).first)
        #expect(opened.agent.state == .idle && opened.agent.since == start && opened.agent.app == "com.apple.Terminal")
        #expect(board.counts.isEmpty)
        // It is still there well after the active window, until the recent one is over.
        #expect(listed(board, at: start.addingTimeInterval(AgentBoard.recentWindow - 1)).count == 1)
        #expect(listed(board, at: start.addingTimeInterval(AgentBoard.recentWindow)).isEmpty)
    }

    @Test func openingAgainNeverClobbersATurnInProgress() throws {
        let (hooks, board) = make()
        hooks.apply(event("w", .working, app: "com.apple.Terminal"), now: start)
        hooks.apply(event("q", .needsInput), now: start)
        hooks.apply(event("f", .finished), now: start)
        // Compact comes mid-turn; resume and clear start over from wherever the session was.
        let later = start.addingTimeInterval(300)
        for id in ["w", "q", "f"] { hooks.apply(event(id, .opened), now: later) }
        let states = Dictionary(uniqueKeysWithValues: listed(board, at: later).map { ($0.id, $0.agent) })
        #expect(states["w"]?.state == .working && states["w"]?.since == start && states["w"]?.idleFrom == start.addingTimeInterval(AgentHooks.activeWindow))
        #expect(states["q"]?.state == .waiting && states["q"]?.since == start && states["q"]?.finished == false)
        #expect(states["f"]?.state == .waiting && states["f"]?.finished == true)
        // An app it didn't say before is kept; one missing doesn't erase what was known.
        #expect(states["w"]?.app == "com.apple.Terminal")
        hooks.apply(event("w", .opened, app: "com.mitchellh.ghostty"), now: later)
        #expect(listed(board, at: later, "w").first?.agent.app == "com.mitchellh.ghostty")
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 2))
    }

    @Test func openingRefreshesTheExpiry() {
        let (hooks, board) = make()
        hooks.apply(event("a", .working), now: start)
        hooks.apply(event("a", .opened), now: start.addingTimeInterval(3_600))
        #expect(listed(board, at: start.addingTimeInterval(3_600 + AgentBoard.recentWindow - 1)).count == 1)
    }

    @Test func sessionEndRemovesIdleSessionsToo() {
        let (hooks, board) = make()
        hooks.apply(event("a", .opened), now: start)
        hooks.apply(event("a", .remove), now: start)
        #expect(listed(board, at: start).isEmpty)
    }

    @Test func comingToTheAppMakesItsFinishedHandsIdle() throws {
        let (hooks, board) = make()
        let now = Date.now
        hooks.apply(event("a", .finished, app: "com.mitchellh.ghostty"), now: now)
        hooks.apply(event("b", .finished, app: "com.apple.Terminal"), now: now)
        hooks.apply(event("c", .working, app: "com.mitchellh.ghostty"), now: now)
        hooks.activated("com.mitchellh.ghostty")
        let states = Dictionary(uniqueKeysWithValues: listed(board, at: .now).map { ($0.id, $0.agent) })
        #expect(states["a"]?.state == .idle && states["a"]?.finished == false && states["a"]?.idleFrom == nil)
        #expect(try #require(states["a"]?.since) >= now)
        #expect(states["a"]?.app == "com.mitchellh.ghostty")
        #expect(states["b"]?.state == .waiting && states["c"]?.state == .working)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
    }

    @Test func theSameEventAfterTheHandWentIdleStartsAgain() throws {
        let (hooks, board) = make()
        let late = start.addingTimeInterval(AgentHooks.activeWindow + 5 * 60)
        for action in [AgentAction.needsInput, .working] {
            hooks.apply(event("a", action), now: start)
            #expect(listed(board, at: late).first?.agent.state == .idle)
            hooks.apply(event("a", action), now: late)
            let again = try #require(listed(board, at: late).first)
            #expect(again.agent.state == (action == .working ? .working : .waiting) && again.agent.since == late, "\(action)")
        }
        let afterDone = start.addingTimeInterval(Herdr.doneWindow + 60)
        hooks.apply(event("b", .finished, app: "com.apple.Terminal"), now: start)
        hooks.apply(event("b", .finished, app: "com.apple.Terminal"), now: afterDone)
        let hand = try #require(listed(board, at: afterDone, "b").first)
        #expect(hand.agent.state == .waiting && hand.agent.finished && hand.agent.since == afterDone)
        // An idle prompt over a hand that is idle already keeps the time it went idle at.
        hooks.apply(event("c", .needsInput), now: start)
        hooks.apply(event("c", .idle), now: late)
        #expect(listed(board, at: late, "c").first?.agent.since == start.addingTimeInterval(AgentHooks.activeWindow))
    }

    @Test func comingToTheAppKeepsWhenAnIdleHandWentIdle() throws {
        let (hooks, board) = make()
        let now = Date.now
        let finishedAt = now.addingTimeInterval(-Herdr.doneWindow - 60)
        hooks.apply(event("a", .finished, app: "com.apple.Terminal"), now: finishedAt)
        hooks.activated("com.apple.Terminal")
        let idle = try #require(listed(board, at: now).first)
        #expect(idle.agent.state == .idle && idle.agent.since == finishedAt.addingTimeInterval(Herdr.doneWindow))
    }

    @Test func expiredSessionsAreFreedAndStopTheLivenessCheck() {
        let (hooks, board) = make()
        hooks.apply(event("a", .working, pid: 900), now: .now.addingTimeInterval(-AgentBoard.recentWindow - 1))
        #expect(hooks.liveness?.isValid == true)
        let timer = hooks.liveness
        hooks.pruneDead()
        #expect(hooks.liveness == nil && timer?.isValid == false)
        #expect(board.entries().isEmpty)
    }

    // MARK: Processes

    @Test func anotherSessionOfTheSameProcessReplacesTheFirst() {
        let (hooks, board) = make()
        hooks.apply(event("old", .working, pid: 900), now: start)
        hooks.apply(event("other", .working, pid: 901), now: start)
        hooks.apply(event("nopid", .working), now: start)
        // /clear or /resume inside process 900: a new id, the old one is no more.
        hooks.apply(event("new", .opened, pid: 900), now: start.addingTimeInterval(5))
        #expect(listed(board, at: start.addingTimeInterval(5)).map(\.id) == ["new", "nopid", "other"])
        // The same id again is the same session, not a duplicate to drop.
        hooks.apply(event("new", .working, pid: 900), now: start.addingTimeInterval(6))
        #expect(listed(board, at: start.addingTimeInterval(6)).map(\.id) == ["new", "nopid", "other"])
        #expect(board.counts == AgentBoard.Counts(working: 3))
    }

    @Test func anEndingSessionDoesNotTakeItsSuccessorsWithIt() {
        let (hooks, board) = make()
        hooks.apply(event("new", .opened, pid: 900), now: start)
        hooks.apply(event("old", .remove, pid: 900), now: start)
        #expect(listed(board, at: start).map(\.id) == ["new"])
    }

    @Test func aSessionKeepsItsProcessThroughEventsThatDontSayIt() {
        var alive = true
        let (hooks, board) = make(isAlive: { _ in alive })
        hooks.apply(event("a", .opened, pid: 900), now: start)
        hooks.apply(event("a", .working), now: start.addingTimeInterval(1))
        alive = false
        hooks.apply(event("b", .working), now: start.addingTimeInterval(2))
        #expect(listed(board, at: start.addingTimeInterval(2)).map(\.id) == ["b"])
    }

    @Test func sessionsWhoseProcessIsGoneAreDroppedOnTheNextEvent() {
        var dead: Set<Int32> = []
        let (hooks, board) = make(isAlive: { !dead.contains($0) })
        hooks.apply(event("a", .working, pid: 900), now: start)
        hooks.apply(event("b", .working, pid: 901), now: start)
        hooks.apply(event("c", .working), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 3))
        dead = [900]
        hooks.apply(event("c", .working), now: start.addingTimeInterval(1))
        #expect(listed(board, at: start.addingTimeInterval(1)).map(\.id) == ["b", "c"])
        #expect(board.counts == AgentBoard.Counts(working: 2))
        // One that arrives with a dead process is never listed.
        hooks.apply(event("d", .working, pid: 900), now: start.addingTimeInterval(2))
        #expect(listed(board, at: start.addingTimeInterval(2)).map(\.id) == ["b", "c"])
    }

    @Test func theLivenessCheckRunsOnlyWhileASessionHasAProcess() {
        var dead: Set<Int32> = []
        let (hooks, board) = make(isAlive: { !dead.contains($0) })
        #expect(hooks.liveness == nil)
        hooks.apply(event("a", .working), now: start)
        #expect(hooks.liveness == nil)
        hooks.apply(event("b", .working, pid: 900), now: start)
        #expect(hooks.liveness?.isValid == true)
        let timer = hooks.liveness
        hooks.apply(event("c", .working, pid: 901), now: start)
        #expect(hooks.liveness === timer)

        // The timer finds a process gone without any event.
        dead = [900]
        hooks.pruneDead(now: start)
        #expect(listed(board, at: start).map(\.id) == ["a", "c"])
        #expect(hooks.liveness?.isValid == true)
        dead = [900, 901]
        hooks.pruneDead(now: start)
        #expect(listed(board, at: start).map(\.id) == ["a"])
        #expect(hooks.liveness == nil && timer?.isValid == false)

        hooks.apply(event("d", .working, pid: 902), now: start)
        #expect(hooks.liveness?.isValid == true)
        hooks.reset()
        #expect(hooks.liveness == nil)
        #expect(listed(board, at: start).isEmpty)
    }

    @Test func aRunningProcessIsAliveAndOneThatEndedIsNot() throws {
        let board = AgentBoard()
        let hooks = AgentHooks(board: board, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil })
        hooks.apply(event("me", .working, pid: getpid()), now: .now)
        #expect(board.entries().map(\.id) == ["me"])
        // Process 1 belongs to another user: not allowed to signal it, but it runs.
        hooks.apply(event("init", .working, pid: 1), now: .now)
        #expect(board.entries().map(\.id).sorted() == ["init", "me"])

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        hooks.apply(event("gone", .working, pid: child.processIdentifier), now: .now)
        #expect(board.entries().map(\.id).sorted() == ["init", "me"])
        hooks.reset()
    }
}
