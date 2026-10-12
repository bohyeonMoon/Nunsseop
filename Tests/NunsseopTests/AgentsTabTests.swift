import AppKit
import Foundation
import Testing
@testable import Nunsseop

@MainActor
struct AgentsTabTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(_ id: String, _ agent: AgentBoard.Agent, source: String = "hooks:claude") -> AgentBoard.Entry {
        AgentBoard.Entry(source: source, id: id, agent: agent)
    }

    private func rowFor(_ agent: AgentBoard.Agent, _ transcript: AgentTranscript? = nil) -> AgentRow {
        AgentRow(entry("s", agent), transcript: transcript)
    }

    @Test func aRowShowsTheFolderToolModelAndContext() {
        let row = rowFor(AgentBoard.Agent(state: .working, tool: "claude"),
                      AgentTranscript(cwd: "/Users/me/Projects/nunsseop", model: "claude-opus-5-5", tokens: 84_300))
        #expect(row.title == "nunsseop" && row.path == "/Users/me/Projects/nunsseop")
        #expect(row.details == ["Claude Code", "Opus 5.5", "84k"])
        #expect(row.symbol == "bolt.fill")
    }

    @Test func aNameIsTheTitleAndTheFolderMovesIntoTheDetails() {
        let transcript = AgentTranscript(cwd: "/Users/me/Projects/nunsseop", model: "claude-opus-5-5", tokens: 84_300, mode: .plan, name: "Agents tab")
        let row = rowFor(AgentBoard.Agent(state: .working, tool: "claude"), transcript)
        #expect(row.title == "Agents tab" && row.name == "Agents tab")
        #expect(row.details == ["nunsseop", "Claude Code", "Plan", "Opus 5.5", "84k"])
        // The state still comes first, and the tooltip's path is still the full one.
        let waiting = rowFor(AgentBoard.Agent(state: .waiting, tool: "claude"), transcript)
        #expect(waiting.details == ["Needs input", "nunsseop", "Claude Code", "Plan", "Opus 5.5", "84k"])
        #expect(waiting.path == "/Users/me/Projects/nunsseop")
        #expect(rowFor(AgentBoard.Agent(state: .idle, tool: "claude"), transcript).details.first == "Idle")
    }

    @Test func aNameWithoutAFolderStillSaysTheTool() {
        let row = rowFor(AgentBoard.Agent(state: .working, tool: "codex"), AgentTranscript(name: "refactor"))
        #expect(row.title == "refactor" && row.details == ["Codex"])
        // Without a name the title is as it was.
        let plain = rowFor(AgentBoard.Agent(state: .working, tool: "claude"), AgentTranscript(cwd: "/a/nunsseop", name: nil))
        #expect(plain.title == "nunsseop" && plain.details == ["Claude Code"])
    }

    @Test func aNameThatIsTheFolderIsNotSaidTwice() {
        let row = rowFor(AgentBoard.Agent(state: .working, tool: "claude"), AgentTranscript(cwd: "/Users/me/Nunsseop", name: "nunsseop"))
        #expect(row.title == "nunsseop" && row.details == ["Claude Code"])
    }

    @Test func theDemoShowsBothANamedAndAnUnnamedRow() {
        #expect(AgentBoard.demoTranscripts["demo|a"]?.name == "Agents tab")
        #expect(AgentBoard.demoTranscripts["demo|b"]?.name == nil)
    }

    @Test func theModeIsShownAfterTheToolOnlyWhenItIsNotTheDefault() {
        let agent = AgentBoard.Agent(state: .working, tool: "claude", cwd: "/a/b")
        let details = { (mode: AgentMode?) in rowFor(agent, AgentTranscript(model: "claude-opus-5-5", tokens: 84_300, mode: mode)).details }
        #expect(details(.plan) == ["Claude Code", "Plan", "Opus 5.5", "84k"])
        #expect(details(.bypass) == ["Claude Code", "Bypass permissions", "Opus 5.5", "84k"])
        #expect(details(.standard) == ["Claude Code", "Opus 5.5", "84k"])
        #expect(details(nil) == ["Claude Code", "Opus 5.5", "84k"])
        let waiting = AgentBoard.Agent(state: .waiting, tool: "codex")
        #expect(rowFor(waiting, AgentTranscript(mode: .fullAccess)).details == ["Needs input", "Full access"])
    }

    @Test func modeLabelsAndWhichOnesWarn() {
        #expect(AgentMode.standard.label == nil)
        #expect(AgentMode.plan.label == "Plan" && AgentMode.acceptEdits.label == "Auto-accept edits")
        #expect(AgentMode.auto.label == "Auto" && AgentMode.dontAsk.label == "Don't ask")
        #expect(AgentMode.bypass.label == "Bypass permissions" && AgentMode.fullAccess.label == "Full access")
        #expect([AgentMode.standard, .plan, .acceptEdits, .auto, .dontAsk].allSatisfy { !$0.warns })
        #expect(AgentMode.bypass.warns && AgentMode.fullAccess.warns)
    }

    @Test func aMissingTranscriptStillShowsTheRowWithoutWhatIsUnknown() {
        let unknown = rowFor(AgentBoard.Agent(state: .working, tool: "codex", app: "com.apple.Terminal"))
        #expect(unknown.title == "Codex" && unknown.path == nil && unknown.model == nil && unknown.tokens == nil)
        // The tool is the title, so the details don't say it again.
        #expect(unknown.details.isEmpty)
        // A folder without a model or context, as with herdr.
        let folderOnly = rowFor(AgentBoard.Agent(state: .working, tool: "pi", cwd: "/Users/me/api/"))
        #expect(folderOnly.title == "api" && folderOnly.details == ["pi"])
    }

    @Test func theTranscriptsFolderIsOnlyUsedWhenTheSourceHasNone() {
        let herdr = rowFor(AgentBoard.Agent(state: .working, tool: "claude", cwd: "/Users/me/now"), AgentTranscript(cwd: "/Users/me/start"))
        #expect(herdr.path == "/Users/me/now")
        #expect(rowFor(AgentBoard.Agent(state: .working, tool: "claude", cwd: ""), AgentTranscript(cwd: "/Users/me/start")).path == "/Users/me/start")
    }

    @Test func waitingSaysWhetherItNeedsYouOrIsDone() {
        let asking = rowFor(AgentBoard.Agent(state: .waiting, tool: "claude", cwd: "/a/b"), AgentTranscript(model: "claude-opus-5-5"))
        #expect(asking.details == ["Needs input", "Claude Code", "Opus 5.5"] && asking.symbol == "hand.raised.fill")
        let done = rowFor(AgentBoard.Agent(state: .waiting, finished: true, tool: "claude", cwd: "/a/b"))
        #expect(done.details == ["Your turn", "Claude Code"] && done.symbol == "hand.raised.fill")
    }

    @Test func idleRowsAreDimmedAndSayIdle() {
        let idle = rowFor(AgentBoard.Agent(state: .idle, tool: "claude", cwd: "/a/b"), AgentTranscript(model: "claude-opus-5-5", tokens: 12_400))
        #expect(idle.details == ["Idle", "Claude Code", "Opus 5.5", "12k"])
        #expect(idle.detailParts.first?.warns == false)
        #expect(idle.symbol == "moon.zzz.fill" && idle.tint == .white.opacity(0.45))
        #expect(NSImage(systemSymbolName: idle.symbol, accessibilityDescription: nil) != nil)
        // Without a folder the tool is the title, and the state still comes first.
        #expect(rowFor(AgentBoard.Agent(state: .idle, tool: "codex")).details == ["Idle"])
        // The other states are as they were.
        #expect(rowFor(AgentBoard.Agent(state: .working, tool: "codex")).details.isEmpty)
        #expect(rowFor(AgentBoard.Agent(state: .working, tool: "codex")).tint == .green)
        #expect(rowFor(AgentBoard.Agent(state: .waiting, tool: "codex")).tint == .yellow)
    }

    @Test func toolNames() {
        #expect(AgentRow.toolName("claude") == "Claude Code")
        #expect(AgentRow.toolName("Claude-Code") == "Claude Code")
        #expect(AgentRow.toolName("codex") == "Codex")
        #expect(AgentRow.toolName("pi") == "pi")
        #expect(AgentRow.toolName(nil) == "herdr" && AgentRow.toolName("") == "herdr")
    }

    @Test func timeSinceTheStateBegan() {
        let label = { (seconds: TimeInterval) in AgentRow.elapsed(since: now.addingTimeInterval(-seconds), now: now) }
        #expect(label(0) == "<1m" && label(59) == "<1m")
        #expect(label(60) == "1m" && label(190) == "3m" && label(3_599) == "59m")
        #expect(label(3_600) == "1h" && label(86_399) == "23h")
        #expect(label(86_400) == "1d" && label(3 * 86_400) == "3d")
        #expect(AgentRow.elapsed(since: nil, now: now) == nil)
        // A clock that moved back doesn't show a negative time.
        #expect(AgentRow.elapsed(since: now.addingTimeInterval(30), now: now) == "<1m")
    }

    @Test func waitingFirstThenWorkingThenIdleThenTheMostRecentChange() {
        let make = { (id: String, state: AgentBoard.State, ago: TimeInterval?) in
            AgentRow(entry(id, AgentBoard.Agent(state: state, since: ago.map { now.addingTimeInterval(-$0)})), transcript: nil)
        }
        let sorted = AgentRow.sorted([
            make("working-old", .working, 900), make("waiting-old", .waiting, 600), make("working-new", .working, 30),
            make("waiting-new", .waiting, 20), make("working-unknown", .working, nil), make("waiting-unknown", .waiting, nil),
            make("idle-old", .idle, 7_000), make("idle-new", .idle, 5), make("idle-unknown", .idle, nil),
        ])
        #expect(sorted.map(\.id) == ["hooks:claude|waiting-new", "hooks:claude|waiting-old", "hooks:claude|waiting-unknown",
                                     "hooks:claude|working-new", "hooks:claude|working-old", "hooks:claude|working-unknown",
                                     "hooks:claude|idle-new", "hooks:claude|idle-old", "hooks:claude|idle-unknown"])
    }

    @Test func aClickGoesToTheHerdrPaneElseTheTerminalApp() {
        let herdr = AgentBoard.Agent(state: .waiting, tool: "pi", app: "com.apple.Terminal", pane: "w1:p2", socket: "/tmp/herdr.sock")
        #expect(AgentRow.target(for: herdr) == .herdr(pane: "w1:p2", socket: "/tmp/herdr.sock"))
        #expect(AgentRow.target(for: AgentBoard.Agent(state: .working, tool: "claude", app: "com.mitchellh.ghostty")) == .app("com.mitchellh.ghostty"))
        // A background session has no app, and nothing else says where it is.
        #expect(AgentRow.target(for: AgentBoard.Agent(state: .working, tool: "claude")) == nil)
        #expect(AgentRow.target(for: AgentBoard.Agent(state: .working, tool: "pi", pane: "w1:p2")) == nil)
        #expect(rowFor(herdr).target == .herdr(pane: "w1:p2", socket: "/tmp/herdr.sock"))
    }

    @Test func transcriptsAreLookedUpByToolAndSession() {
        #expect(AgentRow.transcriptKey(AgentBoard.Agent(state: .working, tool: "claude", session: "s1"))
                == AgentTranscripts.Key(kind: .claude, session: "s1"))
        #expect(AgentRow.transcriptKey(AgentBoard.Agent(state: .working, tool: "codex", session: "s2"))
                == AgentTranscripts.Key(kind: .codex, session: "s2"))
        // herdr names its agent; one it doesn't know the files of, or without a session id, has none.
        #expect(AgentRow.transcriptKey(AgentBoard.Agent(state: .working, tool: "claude-code", session: "s3"))?.kind == .claude)
        #expect(AgentRow.transcriptKey(AgentBoard.Agent(state: .working, tool: "pi", session: "s4")) == nil)
        #expect(AgentRow.transcriptKey(AgentBoard.Agent(state: .working, tool: "claude")) == nil)
    }
}

@MainActor
struct AgentsBoardFeedTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func make(_ agent: AgentKind = .claude) -> (hooks: AgentHooks, board: AgentBoard) {
        let board = AgentBoard()
        return (AgentHooks(board: board, agent: agent, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }), board)
    }

    private func event(_ session: String, _ action: AgentAction, app: String? = "com.apple.Terminal", agent: AgentKind = .claude) -> AgentEvent {
        AgentEvent(session: session, action: action, app: app, inHerdr: false, agent: agent)
    }

    @Test func hookSessionsReachTheBoardWithTheirToolSessionAppAndSince() throws {
        let (hooks, board) = make(.codex)
        hooks.apply(event("019e-a", .working, agent: .codex), now: start)
        let listed = try #require(board.entries(now: start).first)
        #expect(listed.source == "hooks:codex" && listed.id == "019e-a" && listed.key == "hooks:codex|019e-a")
        #expect(listed.agent == AgentBoard.Agent(state: .working, expiresAt: start.addingTimeInterval(AgentBoard.recentWindow), since: start,
                                                 finished: false, tool: "codex", app: "com.apple.Terminal", session: "019e-a",
                                                 idleFrom: start.addingTimeInterval(AgentHooks.activeWindow)))
    }

    @Test func sinceKeepsThroughEventsInTheSameStateAndRestartsOnAChange() throws {
        let (hooks, board) = make()
        let since = { try #require(board.entries(now: start).first?.agent.since) }
        hooks.apply(event("a", .working), now: start)
        hooks.apply(event("a", .working), now: start.addingTimeInterval(120))
        #expect(try since() == start)
        hooks.apply(event("a", .needsInput), now: start.addingTimeInterval(180))
        #expect(try since() == start.addingTimeInterval(180))
        hooks.apply(event("a", .needsInput), now: start.addingTimeInterval(240))
        #expect(try since() == start.addingTimeInterval(180))
        // Finished is another kind of waiting.
        hooks.apply(event("a", .finished), now: start.addingTimeInterval(300))
        let finished = try #require(board.entries(now: start.addingTimeInterval(300)).first?.agent)
        #expect(finished.since == start.addingTimeInterval(300) && finished.finished && finished.state == .waiting)
    }

    @Test func herdrPanesReachTheBoardWithTheirAgentFolderSessionAndPane() throws {
        let panes = ["w1:p1": Herdr.PaneState(status: "blocked", since: start, agent: "claude", cwd: "/Users/me/api", session: "abc-1"),
                     "w1:p2": Herdr.PaneState(status: "done", since: start, agent: "pi"),
                     "w1:p3": Herdr.PaneState(status: "idle", since: start, agent: "claude")]
        let agents = Herdr.boardAgents(panes, socket: "/tmp/herdr.sock")
        // The idle pane with an agent in it is listed, as idle.
        #expect(agents.keys.sorted() == ["w1:p1", "w1:p2", "w1:p3"])
        #expect(agents["w1:p1"] == AgentBoard.Agent(state: .waiting, since: start, finished: false, tool: "claude", pane: "w1:p1",
                                                    socket: "/tmp/herdr.sock", cwd: "/Users/me/api", session: "abc-1",
                                                    input: .herdr(pane: "w1:p1", socket: "/tmp/herdr.sock")))
        #expect(agents["w1:p2"]?.finished == true && agents["w1:p2"]?.idleFrom == start.addingTimeInterval(Herdr.doneWindow))
        #expect(agents["w1:p2"]?.expiresAt == start.addingTimeInterval(AgentBoard.recentWindow))
        #expect(agents["w1:p3"]?.state == .idle && agents["w1:p3"]?.expiresAt == start.addingTimeInterval(AgentBoard.recentWindow))
    }

    @Test func herdrsPaneListGivesTheFolderAndTheSessionIdOnlyWhenItIsOne() throws {
        let list: [String: Any] = ["result": ["panes": [
            ["pane_id": "w1:p1", "agent_status": "working", "agent": "claude", "cwd": "/Users/me", "foreground_cwd": "/Users/me/api",
             "agent_session": ["source": "herdr:claude", "agent": "claude", "kind": "id", "value": "abc-1"]],
            ["pane_id": "w1:p2", "agent_status": "idle", "agent": "pi", "cwd": "/Users/me/web",
             "agent_session": ["source": "herdr:pi", "agent": "pi", "kind": "path", "value": "/Users/me/.pi/s.jsonl"]],
            ["pane_id": "w1:p3", "agent_status": "unknown", "cwd": "/Users/me"],
        ]]]
        let panes = try #require(Herdr.panes(in: list))
        #expect(panes.map(\.cwd) == ["/Users/me/api", "/Users/me/web", "/Users/me"])
        #expect(panes.map(\.session) == ["abc-1", nil, nil])
    }

    @Test func theAgentsTabKeepsHooksAndHerdrRunning() {
        let settings = AppSettings.shared
        let saved = (settings.herdrNotifications, settings.idleLeft, settings.idleRight, settings.agentsTab)
        defer { (settings.herdrNotifications, settings.idleLeft, settings.idleRight, settings.agentsTab) = saved }
        settings.herdrNotifications = false
        settings.idleLeft = .none
        settings.idleRight = .none
        settings.agentsTab = false
        #expect(!settings.watchesHerdr)
        settings.agentsTab = true
        #expect(settings.watchesHerdr)
        #expect(settings.visibleTabs.contains(.agents))
        settings.agentsTab = false
        #expect(!settings.visibleTabs.contains(.agents))
    }

    @Test func theTabIsOnByDefaultAndSitsBeforeMirror() {
        #expect(UserDefaults.standard.object(forKey: "agentsTab") != nil || AppSettings.shared.agentsTab)
        let order = AppSettings.orderedTabs(saved: [])
        #expect(order.contains(.agents))
        #expect(order.firstIndex(of: .agents)! < order.firstIndex(of: .mirror)!)
        #expect(NotchTab.agents.title == "Agents" && NotchTab.agents.symbol == "list.bullet.rectangle")
    }
}

@MainActor
struct AgentsTabModelTests {
    /// Waits, for at most 30 seconds, until the condition holds.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(eventDeadline)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @Test func demoRowsAreTwoWorkingOneWaitingOneIdleAndOneCodex() {
        let board = AgentBoard()
        board.replace(source: "demo", with: AgentBoard.demoAgents())
        let model = AgentsTabModel(board: board, isConnected: { true })
        model.fixed = AgentBoard.demoTranscripts
        model.refresh()
        #expect(board.counts == AgentBoard.Counts(working: 3, waiting: 1))
        // Waiting first, then the rest by most recent change.
        #expect(model.rows.map(\.title) == ["api-server", "site", "Agents tab", "ios-app", "docs"])
        #expect(model.rows.map(\.state) == [.waiting, .working, .working, .working, .idle])
        #expect(model.rows.filter { $0.tool == "Codex" }.count == 1)
        #expect(model.rows[0].details == ["Needs input", "Claude Code", "Opus 5.5", "142k"])
        #expect(model.rows[1].details == ["Claude Code", "Plan", "Sonnet 5.5", "32k"])
        #expect(model.rows[2].details == ["nunsseop", "Claude Code", "Opus 5.5", "84k"])
        #expect(model.rows.filter { $0.mode != nil }.count == 1)
        #expect(model.rows[3].details == ["Codex", "gpt-5.6", "20k"])
        // The idle one is listed last and isn't counted.
        #expect(model.rows[4].details == ["Idle", "Claude Code", "Sonnet 5.5", "12k"])
    }

    @Test func anEmptyTabSaysSoWhenConnectedAndHowToConnectWhenNot() {
        let board = AgentBoard()
        var connected = false
        let model = AgentsTabModel(board: board, isConnected: { connected })
        #expect(!model.connected)
        #expect(model.emptyMessage == "Connect Claude Code and Codex in Settings › Alerts to see their sessions here")
        // It is looked at when the tab appears, not at every change of the board.
        connected = true
        #expect(!model.connected)
        model.isShowing = true
        #expect(model.connected)
        #expect(model.emptyMessage == "No sessions used in the last 3 hours")
        #expect(model.rows.isEmpty)
        model.isShowing = false
        connected = false
        model.isShowing = true
        #expect(!model.connected)
    }

    @Test func connectedMeansTheNoticeHookOrCodexsNotifyIsInThatHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-conn-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let model = AgentsTabModel(board: AgentBoard(), home: { home })
        model.isShowing = true
        #expect(!model.connected)
        model.isShowing = false
        try NotifyIntegration.$homeOverride.withValue(home) { try NotifyIntegration.claudeCode.installNow() }
        model.isShowing = true
        #expect(model.connected)
    }

    @Test func rowsGetTheirFolderModelAndContextFromTheSessionFilesOffTheMainThread() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-agents-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/projects/-Users-me-api/s1.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((["{\"type\":\"user\",\"cwd\":\"/Users/me/api\",\"permissionMode\":\"acceptEdits\"}",
                   "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":5,"
                   + "\"cache_read_input_tokens\":60000,\"cache_creation_input_tokens\":0}}}"].joined(separator: "\n") + "\n").utf8).write(to: file)

        let board = AgentBoard()
        let model = AgentsTabModel(board: board, home: { home }, isConnected: { false })
        board.replace(source: "hooks:claude", with: [
            "s1": AgentBoard.Agent(state: .working, since: .now, tool: "claude", app: "com.apple.Terminal", session: "s1"),
            "gone": AgentBoard.Agent(state: .waiting, since: .now, tool: "claude", session: "gone"),
        ])
        // Nothing is read while the tab isn't showing.
        #expect(model.rows.isEmpty)
        model.isShowing = true
        // The rows are there at once, with what isn't known yet left out, then fill in.
        #expect(model.rows.count == 2)
        #expect(await eventually { model.rows.first { $0.id == "hooks:claude|s1" }?.tokens != nil })
        let found = try #require(model.rows.first { $0.id == "hooks:claude|s1" })
        #expect(found.title == "api" && found.details == ["Claude Code", "Auto-accept edits", "Opus 5.5", "60k"] && found.target == .app("com.apple.Terminal"))
        let missing = try #require(model.rows.first { $0.id == "hooks:claude|gone" })
        #expect(missing.title == "Claude Code" && missing.model == nil && missing.tokens == nil)

        // The board changing refreshes the rows while the tab shows.
        board.clear(source: "hooks:claude")
        #expect(model.rows.isEmpty)
        model.isShowing = false
        board.replace(source: "hooks:claude", with: ["s1": AgentBoard.Agent(state: .working, tool: "claude", session: "s1")])
        #expect(model.rows.isEmpty)
    }
}
