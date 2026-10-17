import Foundation
import Testing
@testable import Nunsseop

struct AgentKindTests {
    @Test func aToolIsKnownByTheNamesItGoesBy() {
        let names: [String: AgentKind] = ["claude": .claude, "Claude-Code": .claude, "codex": .codex, "pi": .pi, "PI": .pi, "omp": .omp,
                                          "oh-my-pi": .omp, "gjc": .gjc, "gajae-code": .gjc, "omo": .omo, "opencode": .opencode, "OpenCode": .opencode,
                                          "gemini": .gemini, "Gemini CLI": .gemini, "gemini-cli": .gemini, "copilot": .copilot, "GitHub Copilot": .copilot,
                                          "agy": .agy, "Antigravity": .agy, "cursor": .cursor, "cursor-agent": .cursor, "hermes": .hermes,
                                          "hermes-agent": .hermes, "amp": .amp, "AMP": .amp]
        for (name, kind) in names { #expect(AgentKind(tool: name) == kind, "\(name)") }
        for other in ["", "Pi Coding Agent", "herdr", "hermes agent", "claude code", "a name for a session", "ampere"] { #expect(AgentKind(tool: other) == nil, "\(other)") }
        #expect(AgentKind(tool: nil) == nil)
    }

    @Test func eachToolIsNamedAsItPresentsItself() {
        #expect(AgentKind.allCases.map(\.displayName) == ["Claude Code", "Codex", "pi", "omp", "gjc", "omo", "OpenCode", "Gemini CLI", "GitHub Copilot", "Antigravity", "Cursor", "Hermes", "Amp"])
        #expect(AgentRow.toolName("omp") == "omp" && AgentRow.toolName("OpenCode") == "OpenCode" && AgentRow.toolName("claude") == "Claude Code")
        // A name that isn't a tool's is shown as it is, and nothing at all is herdr's.
        #expect(AgentRow.toolName("hermes") == "Hermes" && AgentRow.toolName("a tool of its own") == "a tool of its own" && AgentRow.toolName(nil) == "herdr" && AgentRow.toolName("") == "herdr")
        #expect(AgentKind.allCases.filter(\.isPiFamily) == [.pi, .omp, .gjc, .omo])
        #expect(AgentKind.allCases.filter(\.reportsMode) == [.claude, .codex])
    }

    @Test func aConversationIsResumedWithTheFlagEachToolTakes() {
        let id = "01a12655-029b-786a-b1ff-45131b52e032"
        let expected: [AgentKind: String] = [
            .claude: "claude --resume '\(id)'", .codex: "codex resume '\(id)'", .pi: "pi --session '\(id)'", .omo: "omo --session '\(id)'",
            // gjc's value is optional: a separate word would be its prompt.
            .omp: "omp --resume='\(id)'", .gjc: "gjc --resume='\(id)'", .opencode: "opencode -s '\(id)'",
            // None of these has a conversation list that Nunsseop reads, so nothing offers to resume one yet.
            .gemini: "gemini --resume='\(id)'", .copilot: "copilot --resume='\(id)'", .agy: "agy --resume '\(id)'",
            .cursor: "cursor-agent --resume='\(id)'", .hermes: "hermes --resume '\(id)'", .amp: "amp threads continue '\(id)'"]
        for kind in AgentKind.allCases { #expect(kind.resumeCommand(session: id) == expected[kind], "\(kind)") }
        for kind in AgentKind.allCases {
            let conversation = RecentConversation(kind: kind, session: id, cwd: "/Users/me/it's here", modified: .now)
            #expect(Resume.line(conversation) == "cd -- '/Users/me/it'\\''s here' && exec \(expected[kind]!)", "\(kind)")
        }
    }

    @Test func openCodeIdsAreSafeSessionsToo() {
        for ok in ["ses_1a2b3c4d5e6f7g8h9i0jKLMNOP", "ses_abcdef12"] { #expect(Resume.isSafeSession(ok), "\(ok)") }
        for bad in ["ses_", "ses_a b c d e f", "ses_a;rm -rf", "ses_../../etc", "ses_" + String(repeating: "a", count: 61), "xses_abcdefgh", "SES-abcdefgh"] {
            #expect(!Resume.isSafeSession(bad), "\(bad)")
        }
        // The old ids stay what they were.
        #expect(Resume.isSafeSession("5f0c2d1e-0000-4000-8000-000000000001") && !Resume.isSafeSession("zzzzzzzz"))
        let line = Resume.line(RecentConversation(kind: .opencode, session: OpenCodeFixture.id(1), cwd: "/Users/me/w", modified: .now))
        #expect(line == "cd -- '/Users/me/w' && exec opencode -s '\(OpenCodeFixture.id(1))'")
    }
}

struct AgentEventHeaderTests {
    private func event(agent: String?, event: String = "UserPromptSubmit") -> AgentEvent? {
        var headers = ["x-session": "ses_abc-1", "x-event": event, "x-pid": "4242", "x-app": "com.mitchellh.ghostty"]
        headers["x-agent"] = agent
        return AgentHook.event(headers: headers)
    }

    @Test func everyToolNamesItselfInXAgent() {
        for kind in AgentKind.allCases where kind != .claude {
            let parsed = event(agent: kind.rawValue)
            #expect(parsed == AgentEvent(session: "ses_abc-1", action: .working, app: "com.mitchellh.ghostty", agent: kind, pid: 4242), "\(kind)")
        }
        // Claude Code's hook sends none; a name that is not a tool's is refused.
        #expect(event(agent: nil)?.agent == .claude && event(agent: "")?.agent == .claude)
        for bad in ["Omp", "pi ", "oh-my-pi", "nope", "claude ", "opencode\n"] { #expect(event(agent: bad) == nil, "\(bad)") }
    }

    @Test func theEventsTheExtensionAndThePluginSendAreTheOnesTheCountReads() {
        let sent: [(String, String?, AgentAction)] = [
            ("SessionStart", nil, .opened), ("UserPromptSubmit", nil, .working), ("Stop", nil, .finished), ("SessionEnd", nil, .remove),
            ("Notification", "permission_prompt", .needsInput), ("Notification", "elicitation_complete", .working),
            ("Notification", "idle_prompt", .idle)]
        for (name, type, action) in sent {
            let headers = ["x-session": "s", "x-event": name, "x-type": type ?? "", "x-agent": "omo"]
            #expect(AgentHook.event(headers: headers)?.action == action, "\(name) \(type ?? "")")
        }
    }
}

@MainActor
struct OtherToolHooksTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func eachToolIsASourceOfItsOwnSoSessionIdsCantMeet() {
        let board = AgentBoard()
        let tools = ToolHooks(board: board, isOn: { true }, watchesHerdr: { false })
        for kind in [AgentKind.claude, .codex, .pi, .omp, .omo, .opencode] {
            tools.apply(AgentEvent(session: "same", action: .working, agent: kind), now: start)
        }
        #expect(board.counts == AgentBoard.Counts(working: 6))
        #expect(Set(board.entries(now: start).compactMap(\.agent.tool)) == ["claude", "codex", "pi", "omp", "omo", "opencode"])
        tools.apply(AgentEvent(session: "same", action: .remove, agent: .omp), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 5))
        #expect(!board.entries(now: start).contains { $0.agent.tool == "omp" })
        tools.reset()
        #expect(board.counts.isEmpty)
    }

    @Test func aSessionInAHerdrPaneIsLeftToHerdrWhileItIsWatched() {
        let board = AgentBoard()
        let tools = ToolHooks(board: board, isOn: { true }, watchesHerdr: { true })
        tools.apply(AgentEvent(session: "a", action: .working, inHerdr: true, agent: .omo), now: start)
        #expect(board.counts.isEmpty)
        tools.apply(AgentEvent(session: "b", action: .working, agent: .omo), now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1))
    }
}

struct HerdrOtherAgentsTests {
    private static let piPath = "/Users/me/.pi/agent/sessions/--Users-me-work--/2026-09-06T14-17-31-797Z_01a07714-df95-716e-b644-1f0cf0cb0c97.jsonl"

    /// A `pane.list` answer shaped like herdr's (`agent_session` of kind `path` for the pi family, `id` for the others).
    private func list(_ panes: [[String: Any]]) -> [String: Any] { ["id": "list", "result": ["type": "pane_list", "panes": panes]] }

    @Test func aPiFamilyPaneGivesItsSessionIdFromTheFileItPointsAt() {
        let pane: [String: Any] = ["pane_id": "w1:p1", "agent": "pi", "agent_status": "idle", "foreground_cwd": "/Users/me/work",
                                   "agent_session": ["agent": "pi", "kind": "path", "source": "herdr:pi", "value": Self.piPath]]
        let found = Herdr.panes(in: list([pane]))?.first
        #expect(found == Herdr.Pane(id: "w1:p1", status: "idle", agent: "pi", cwd: "/Users/me/work", session: "01a07714-df95-716e-b644-1f0cf0cb0c97"))
        // A path that isn't a session file says nothing.
        for value in ["/Users/me/notes.txt", "relative/x.jsonl", "/a/2026-09-06T14-17-31-797Z_../../x.jsonl", ""] {
            let odd: [String: Any] = ["pane_id": "p", "agent": "pi", "agent_session": ["kind": "path", "value": value]]
            #expect(Herdr.panes(in: list([odd]))?.first?.session == nil, "\(value)")
        }
        let byID: [String: Any] = ["pane_id": "p", "agent": "claude", "agent_session": ["kind": "id", "value": "f1decd15-957c-4e9c-a188-aa863e715ac8"]]
        #expect(Herdr.panes(in: list([byID]))?.first?.session == "f1decd15-957c-4e9c-a188-aa863e715ac8")
    }

    @Test func omoReportsAsPiAndItsFileSaysWhichItIs() {
        let omoPath = Self.piPath.replacingOccurrences(of: "/.pi/", with: "/.omo/")
        let omo: [String: Any] = ["pane_id": "p", "agent": "pi", "agent_session": ["kind": "path", "value": omoPath]]
        let pi: [String: Any] = ["pane_id": "q", "agent": "pi", "agent_session": ["kind": "path", "value": Self.piPath]]
        let found = Herdr.panes(in: list([omo, pi])) ?? []
        #expect(found.map(\.agent) == ["omo", "pi"])
        #expect(PiSessions.owner(ofPath: omoPath) == .omo && PiSessions.owner(ofPath: Self.piPath) == .pi)
        #expect(PiSessions.owner(ofPath: "/Users/me/.gjc/agent/sessions/v2-x/f.jsonl") == .gjc)
        #expect(PiSessions.owner(ofPath: "/Users/me/.claude/projects/x/f.jsonl") == nil)
    }

    @Test func aLabelInDisplayAgentDoesNotHideWhichToolItIs() {
        // pi and its forks put the session's name in display_agent.
        #expect(Herdr.agentName(display: "Refactor the parser", agent: "omp") == "omp")
        #expect(Herdr.agentName(display: "Claude", agent: "claude") == "Claude")
        #expect(Herdr.agentName(display: nil, agent: "opencode") == "opencode")
        #expect(Herdr.agentName(display: "Some label", agent: "aider") == "Some label")
        #expect(Herdr.agentName(display: nil, agent: nil) == nil)
        let named: [String: Any] = ["pane_id": "p", "agent": "omp", "display_agent": "Refactor the parser", "agent_status": "working"]
        #expect(Herdr.panes(in: list([named]))?.first?.agent == "omp")
        let event = Herdr.event(in: ["event": "pane.agent_status_changed",
                                     "data": ["pane_id": "p", "agent_status": "done", "agent": "opencode", "display_agent": "fix the build"]])
        #expect(event == .status(pane: "p", Herdr.Notice(agent: "opencode", status: "done", title: nil, pane: "p")))
    }

    @Test func theseToolsPanesShowUnderTheirNamesAndAreFoundByTheirSessions() {
        let panes = ["p1": Herdr.PaneState(status: "working", since: .now, agent: "omp", cwd: "/w", session: "01a12655-029b-786a-b1ff-000000000001"),
                     "p2": Herdr.PaneState(status: "idle", since: .now, agent: "opencode", cwd: "/w", session: OpenCodeFixture.id(2)),
                     "p3": Herdr.PaneState(status: "idle", since: .now, agent: "omo", cwd: "/w", session: "01a12655-029b-786a-b1ff-000000000003")]
        let agents = Herdr.boardAgents(panes, socket: "/s")
        let rows = agents.map { id, agent in AgentRow(AgentBoard.Entry(source: "herdr", id: id, agent: agent), transcript: nil) }
        #expect(Set(rows.map(\.tool)) == ["omp", "OpenCode", "omo"])
        #expect(agents.values.compactMap { AgentRow.transcriptKey($0)?.kind }.sorted { $0.rawValue < $1.rawValue } == [.omo, .omp, .opencode])
        // What is open there is not offered again under Recent.
        #expect(Set(agents.values.compactMap(\.session)).contains(OpenCodeFixture.id(2)))
    }
}
