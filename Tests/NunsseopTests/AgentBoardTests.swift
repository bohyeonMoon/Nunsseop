import Foundation
import Testing
@testable import Nunsseop

@MainActor
struct AgentBoardTests {
    @Test func countsAcrossSources() {
        let board = AgentBoard()
        #expect(board.counts.isEmpty)
        board.replace(source: "herdr:a", with: ["p1": .working, "p2": .waiting])
        board.replace(source: "herdr:b", with: ["p1": .working])
        #expect(board.counts == AgentBoard.Counts(working: 2, waiting: 1))
        // A source's new list replaces its old one; others stay.
        board.replace(source: "herdr:a", with: ["p2": .working])
        #expect(board.counts == AgentBoard.Counts(working: 2, waiting: 0))
        board.clear(source: "herdr:b")
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 0))
        board.clear(source: "herdr:a")
        #expect(board.counts.isEmpty)
    }

    @Test func herdrStatesAsTheBoardCountsThem() {
        #expect(Herdr.boardState("working") == .working)
        #expect(Herdr.boardState("blocked") == .waiting)
        #expect(Herdr.boardState("done") == .waiting)
        // An idle pane isn't at work: it is only listed, by boardAgents.
        #expect(Herdr.boardState("idle") == nil)
        #expect(Herdr.boardState("unknown") == nil)
        #expect(Herdr.boardStates(["a": "working", "b": "idle", "c": "blocked"]) == ["a": .working, "c": .waiting])
    }

    @Test func idleAgentsAreNeverCounted() {
        #expect(AgentBoard.Counts([.working, .idle, .waiting, .idle, .idle]) == AgentBoard.Counts(working: 1, waiting: 1))
        #expect(AgentBoard.Counts([.idle]).isEmpty)
        let board = AgentBoard()
        board.replace(source: "s", with: ["a": .idle, "b": .working])
        #expect(board.counts == AgentBoard.Counts(working: 1))
        #expect(board.entries().count == 2)
        #expect(AgentBoard.recentWindow == 3 * 60 * 60)
    }

    @Test func anAgentTurnsIdleFromItsIdleFromOn() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let idleFrom = start.addingTimeInterval(600)
        let agent = AgentBoard.Agent(state: .waiting, expiresAt: start.addingTimeInterval(AgentBoard.recentWindow), since: start,
                                     finished: true, tool: "claude", session: "s", idleFrom: idleFrom)
        let board = AgentBoard()
        board.replace(source: "s", with: ["a": agent], now: start)
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        #expect(try #require(board.entries(now: idleFrom.addingTimeInterval(-1)).first).agent == agent)

        let idle = try #require(board.entries(now: idleFrom).first).agent
        #expect(idle.state == .idle && !idle.finished && idle.since == idleFrom)
        #expect(idle.tool == "claude" && idle.session == "s" && idle.expiresAt == agent.expiresAt)
        board.recount(now: idleFrom)
        #expect(board.counts.isEmpty)
        // It is listed until its expiry, and not after.
        #expect(board.entries(now: start.addingTimeInterval(AgentBoard.recentWindow - 1)).count == 1)
        #expect(board.entries(now: start.addingTimeInterval(AgentBoard.recentWindow)).isEmpty)
        // One that is idle already keeps its own since.
        let idler = AgentBoard.Agent(state: .idle, since: start, idleFrom: idleFrom)
        #expect(idler.effective(at: idleFrom.addingTimeInterval(5)) == idler)
    }

    @Test func theBoardWakesWhenAHandTurnsIdle() async throws {
        let agent = AgentBoard.Agent(state: .waiting, expiresAt: Date.now.addingTimeInterval(3_600), since: .now, finished: true,
                                     idleFrom: Date.now.addingTimeInterval(0.2))
        let board = AgentBoard()
        board.replace(source: "s", with: ["a": agent])
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        let revision = board.revision
        await eventually { board.counts.waiting != 1 }
        #expect(board.counts.isEmpty)
        #expect(board.revision > revision)
    }

    @Test func closedNotchShowsWaitingFirst() {
        #expect(NotchViewModel.agentsValue(AgentBoard.Counts()) == nil)
        let working = NotchViewModel.agentsValue(AgentBoard.Counts(working: 3))
        #expect(working?.text == "3" && working?.symbol == "bolt.fill")
        let waiting = NotchViewModel.agentsValue(AgentBoard.Counts(working: 3, waiting: 1))
        #expect(waiting?.text == "1" && waiting?.symbol == "hand.raised.fill")
    }

    @Test func finishedPanesStopWaitingAfterAWhile() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let panes = ["a": Herdr.PaneState(status: "done", since: start),
                     "b": Herdr.PaneState(status: "blocked", since: start),
                     "c": Herdr.PaneState(status: "working", since: start),
                     "d": Herdr.PaneState(status: "idle", since: start)]
        let agents = Herdr.boardAgents(panes)
        #expect(agents["a"]?.idleFrom == start.addingTimeInterval(Herdr.doneWindow))
        #expect(agents["a"]?.expiresAt == start.addingTimeInterval(AgentBoard.recentWindow))
        #expect(agents["b"]?.expiresAt == nil && agents["b"]?.idleFrom == nil && agents["c"]?.expiresAt == nil)
        // Idle without an agent in it is nothing.
        #expect(agents["d"] == nil)

        let board = AgentBoard()
        board.replace(source: "herdr:x", with: agents, now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 2))
        // Ten minutes on, the finished one nobody looked at no longer counts; asking for input still does.
        board.recount(now: start.addingTimeInterval(Herdr.doneWindow + 1))
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
        // It stays listed, idle, until the recent window is over.
        let later = start.addingTimeInterval(Herdr.doneWindow + 1)
        #expect(board.entries(now: later).first { $0.id == "a" }?.agent.state == .idle)
        #expect(board.entries(now: start.addingTimeInterval(AgentBoard.recentWindow + 1)).first { $0.id == "a" } == nil)
    }

    @Test func herdrIdlePanesWithAnAgentAreListedAsIdle() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let panes = ["a": Herdr.PaneState(status: "idle", since: start, agent: "claude", cwd: "/x/api", session: "s1"),
                     "b": Herdr.PaneState(status: "idle", since: start, agent: ""),
                     "c": Herdr.PaneState(status: "idle", since: start),
                     "d": Herdr.PaneState(status: "unknown", since: start, agent: "claude")]
        let agents = Herdr.boardAgents(panes, socket: "/tmp/herdr.sock")
        #expect(agents.keys.sorted() == ["a"])
        #expect(agents["a"] == AgentBoard.Agent(state: .idle, expiresAt: start.addingTimeInterval(AgentBoard.recentWindow), since: start,
                                                finished: false, tool: "claude", pane: "a", socket: "/tmp/herdr.sock",
                                                cwd: "/x/api", session: "s1", input: .herdr(pane: "a", socket: "/tmp/herdr.sock")))
        let board = AgentBoard()
        board.replace(source: "herdr:x", with: agents, now: start)
        #expect(board.counts.isEmpty)
        #expect(board.entries(now: start).count == 1)
    }

    @Test func herdrIsWatchedForNoticesOrTheAgentsCount() {
        let settings = AppSettings.shared
        let saved = (settings.herdrNotifications, settings.idleLeft, settings.idleRight, settings.agentsTab)
        defer { (settings.herdrNotifications, settings.idleLeft, settings.idleRight, settings.agentsTab) = saved }
        settings.herdrNotifications = false
        settings.agentsTab = false
        settings.idleLeft = .none
        settings.idleRight = .none
        #expect(!settings.watchesHerdr)
        settings.idleRight = .agents
        #expect(settings.watchesHerdr)
        settings.idleRight = .battery
        settings.herdrNotifications = true
        #expect(settings.watchesHerdr)
    }
}
