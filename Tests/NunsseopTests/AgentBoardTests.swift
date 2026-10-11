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
        #expect(Herdr.boardState("idle") == nil)
        #expect(Herdr.boardState("unknown") == nil)
        #expect(Herdr.boardStates(["a": "working", "b": "idle", "c": "blocked"]) == ["a": .working, "c": .waiting])
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
        #expect(agents["a"]?.expiresAt == start.addingTimeInterval(Herdr.doneWindow))
        #expect(agents["b"]?.expiresAt == nil && agents["c"]?.expiresAt == nil && agents["d"] == nil)

        let board = AgentBoard()
        board.replace(source: "herdr:x", with: agents, now: start)
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 2))
        // Ten minutes on, the finished one nobody looked at no longer counts; asking for input still does.
        board.recount(now: start.addingTimeInterval(Herdr.doneWindow + 1))
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
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
