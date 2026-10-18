import Foundation
import Testing
@testable import Nunsseop

/// Above 2^53, where a number read as a Double is rounded.
private let big = "1978299613479001934"
private let biggest = "18446744073709551615"
private let dev = "aa2932bc99a44172845b99e03f715c77"
private let home = "e195adbf56564d6d8fc6962ab22542cb"
private let moment = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func agent(_ session: String = big, project: String = dev, provider: String = "Claude", state: String = "working") -> String {
    #"{"session":"\#(session)","project":"\#(project)","provider":"\#(provider)","state":"\#(state)"}"#
}

private func event(_ id: String, session: String = big, project: String = dev, provider: String = "Claude", kind: String = "Attention",
                   read: Bool = false, timestamp: Int = 1_790_000_000) -> String {
    #"{"id":"\#(id)","session":"\#(session)","project":"\#(project)","provider":"\#(provider)","timestamp":\#(timestamp),"kind":"\#(kind)","read":\#(read)}"#
}

private func listing(revision: Int = 441, agents: [String] = [], events: [String] = []) -> Data {
    Data(#"{"revision":\#(revision),"agents":[\#(agents.joined(separator: ","))],"events":[\#(events.joined(separator: ","))]}"#.utf8)
}

private func activity(revision: Int = 441, agents: [String] = [], events: [String] = []) -> MuxyActivity {
    MuxyActivity.parse(listing(revision: revision, agents: agents, events: events))!
}

private let projectList = Data(#"""
[{"id":"\#(dev)","name":"DEV","directory":"/Users/namkun/Desktop/DEV","directory_bytes":[47],"home":false,"parent_id":null,"kind":null,"color":"#12a594","icon":null},
 {"id":"\#(home)","name":"Home","directory":"/Users/namkun","directory_bytes":[47],"home":true,"parent_id":null,"kind":null,"color":"#d6409f","icon":null}]
"""#.utf8)

struct MuxyActivityParseTests {
    @Test func theCliListIsReadWithIdsAbove2To53Intact() throws {
        let parsed = try #require(MuxyActivity.parse(listing(agents: [agent(big), agent(biggest, state: "blocked")],
                                                             events: [event(biggest, session: big, kind: "Completed", read: true)])))
        #expect(parsed.revision == 441)
        #expect(parsed.agents == [MuxyAgent(session: big, project: dev, provider: "Claude", state: "working"),
                                  MuxyAgent(session: biggest, project: dev, provider: "Claude", state: "blocked")])
        #expect(parsed.events == [MuxyEvent(id: biggest, session: big, project: dev, provider: "Claude", timestamp: 1_790_000_000, kind: .completed, read: true)])
    }

    @Test func idsPrintedAsNumbersAreReadExactlyToo() throws {
        let text = #"{"revision":1,"agents":[{"session":18446744073709551615,"project":"p","provider":"Codex","state":"idle"}],"events":[]}"#
        #expect(try #require(MuxyActivity.parse(Data(text.utf8))).agents.first?.session == biggest)
    }

    @Test func aProviderOrKindItDoesNotKnowStaysUsable() throws {
        let text = #"{"revision":1,"agents":[{"session":"7","project":"p","provider":{"Unrecognized":42},"state":"unknown"}],"events":[{"id":"1","session":"7","project":"p","provider":"Grok","timestamp":5,"kind":"Hello","read":false}]}"#
        let parsed = try #require(MuxyActivity.parse(Data(text.utf8)))
        #expect(parsed.agents.first?.provider == "Agent" && parsed.agents.first?.state == "unknown")
        #expect(parsed.events.first?.kind == .other("Hello") && parsed.events.first?.announces == false)
    }

    @Test func textThatIsNotAnActivityListIsNil() {
        for text in ["", "[]", "{}", "not json", #"{"error":"server not running"}"#, #"{"revision":1"#] {
            #expect(MuxyActivity.parse(Data(text.utf8)) == nil, "\(text)")
        }
        #expect(MuxyActivity.parse(listing()) == MuxyActivity(revision: 441))
    }

    @Test func anEntryWithoutItsIdIsSkipped() throws {
        let text = #"{"revision":1,"agents":[{"project":"p","provider":"Claude","state":"working"},{"session":"","state":"working"}],"events":[{"session":"7"}]}"#
        let parsed = try #require(MuxyActivity.parse(Data(text.utf8)))
        #expect(parsed.agents.isEmpty && parsed.events.isEmpty)
    }

    @Test func projectsGiveNamesAndFolders() throws {
        let projects = try #require(MuxyProjects.parse(projectList))
        #expect(projects.names == [dev: "DEV", home: "Home"])
        #expect(projects.folders[dev] == "/Users/namkun/Desktop/DEV")
        #expect(MuxyProjects.parse(Data("{}".utf8)) == nil)
    }
}

struct MuxyEventTrackerTests {
    @Test func historyIsNotReplayedAndOnlyNewUnreadEventsCome() {
        var tracker = MuxyEventTracker()
        #expect(tracker.fresh(in: activity(revision: 5, events: [event("1")])).isEmpty)
        let next = activity(revision: 7, events: [event("3", kind: "Completed"), event("2", read: true), event("1")])
        #expect(tracker.fresh(in: next).map(\.id) == ["3"])
        // The same list again, and a new revision with the same events, say nothing.
        #expect(tracker.fresh(in: next).isEmpty)
        #expect(tracker.fresh(in: activity(revision: 8, events: next.events.map { _ in event("3") })).isEmpty)
    }

    @Test func aRestartedServerNumbersAnewSoWhatItListsIsOnlyRemembered() {
        var tracker = MuxyEventTracker()
        _ = tracker.fresh(in: activity(revision: 900, events: [event("50")]))
        #expect(tracker.fresh(in: activity(revision: 3, events: [event("1")])).isEmpty)
        #expect(tracker.fresh(in: activity(revision: 4, events: [event("2"), event("1")])).map(\.id) == ["2"])
    }

    @Test func eventsBigIdsAreComparedAsTextNotRounded() {
        var tracker = MuxyEventTracker()
        _ = tracker.fresh(in: activity(events: [event("1978299613479001934")]))
        #expect(tracker.fresh(in: activity(revision: 442, events: [event("1978299613479001934"), event("1978299613479001935")])).map(\.id) == ["1978299613479001935"])
    }
}

struct MuxyNoticeTextTests {
    private func notice(_ provider: String, _ kind: MuxyEvent.Kind, project: String?) -> String? {
        MuxyEvent(id: "1", session: big, project: dev, provider: provider, timestamp: 0, kind: kind, read: false).notice(project: project)
    }

    @Test func theTextNamesTheAgentTheProjectAndWhatHappened() {
        #expect(notice("Claude", .attention, project: "DEV") == "Claude Code in DEV needs input")
        #expect(notice("Codex", .completed, project: "api") == "Codex in api finished")
        #expect(notice("Cursor", .attention, project: "DEV") == "Cursor in DEV needs input")
        #expect(notice("Pi", .completed, project: "x") == "pi in x finished")
    }

    @Test func withoutAProjectNameTheTextStillReads() {
        #expect(notice("Claude", .attention, project: nil) == "Claude Code needs input")
        #expect(notice("OpenCode", .completed, project: "") == "OpenCode finished")
    }

    @Test func aKindItDoesNotKnowHasNoNotice() {
        #expect(notice("Claude", .other("Hello"), project: "DEV") == nil)
    }

    @Test func aToolWithItsOwnHookIsRecognised() {
        func integration(_ provider: String) -> NotifyIntegration? {
            MuxyEvent(id: "1", session: "1", project: "", provider: provider, timestamp: 0, kind: .attention, read: false).integration
        }
        #expect(integration("Claude") == .claudeCode && integration("Codex") == .codex && integration("OpenCode") == .openCode)
        #expect(integration("Cursor") == .cursor && integration("GitHub Copilot") == .copilot && integration("Antigravity") == .antigravity)
        #expect(integration("Aider") == nil && integration("Pi") == nil)
    }
}

struct MuxyBoardTests {
    @Test func onlyWorkingAndBlockedAgentsAreListedWithTheirProjectsFolder() throws {
        var tracker = MuxyBoardTracker()
        let projects = try #require(MuxyProjects.parse(projectList))
        let listed = tracker.agents(for: activity(agents: [agent("1", state: "working"), agent("2", provider: "Codex", state: "blocked"),
                                                           agent("3", state: "idle"), agent("4", state: "unknown"),
                                                           agent(biggest, provider: "Aider", state: "working")]),
                                    projects: projects, now: moment)
        #expect(Set(listed.keys) == ["1", "2", biggest])
        let working = try #require(listed["1"])
        #expect(working.state == .working && working.tool == "claude" && working.cwd == "/Users/namkun/Desktop/DEV")
        #expect(working.app == Muxy.bundleID && working.input == .muxy("1") && working.since == moment && working.pid == nil && !working.finished)
        #expect(listed["2"]?.state == .waiting && listed["2"]?.tool == "codex")
        // A provider with no hook of Nunsseop's keeps the name Muxy gives it.
        #expect(listed[biggest]?.tool == "Aider" && listed[biggest]?.input == .muxy(biggest))
    }

    @Test func aStateKeepsItsStartAcrossLooksAndRestartsWhenItChanges() {
        var tracker = MuxyBoardTracker()
        let later = moment.addingTimeInterval(30)
        _ = tracker.agents(for: activity(agents: [agent("1")]), projects: MuxyProjects(), now: moment)
        #expect(tracker.agents(for: activity(agents: [agent("1")]), projects: MuxyProjects(), now: later)["1"]?.since == moment)
        let blocked = tracker.agents(for: activity(agents: [agent("1", state: "blocked")]), projects: MuxyProjects(), now: later)
        #expect(blocked["1"]?.since == later && blocked["1"]?.cwd == nil)
    }

    @MainActor @Test func aSessionTheHooksAlsoReportIsListedOnceAsTheHookHasIt() {
        let board = AgentBoard()
        board.replace(source: MuxyActivityWatcher.source, with: [
            "1": AgentBoard.Agent(state: .working, since: moment, tool: "claude", app: Muxy.bundleID, input: .muxy("1")),
            "2": AgentBoard.Agent(state: .waiting, since: moment, tool: "Cursor", app: Muxy.bundleID, input: .muxy("2"))])
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
        let hooks = AgentHooks(board: board, isOn: { true }, watchesHerdr: { false })
        hooks.apply(AgentEvent(session: "abc", action: .working, input: .muxy("1")), now: moment)
        // Session 1 is the hook's now; Muxy's own entry for it is hidden, not counted twice.
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
        let entries = board.entries(now: moment)
        #expect(entries.filter { $0.agent.input == .muxy("1") }.map(\.source) == ["hooks:claude"])
        #expect(entries.filter { $0.agent.input == .muxy("2") }.map(\.source) == [MuxyActivityWatcher.source])
        // The hook's session ends: Muxy's entry shows again.
        hooks.apply(AgentEvent(session: "abc", action: .remove, input: .muxy("1")), now: moment)
        #expect(board.entries(now: moment).filter { $0.agent.input == .muxy("1") }.map(\.source) == [MuxyActivityWatcher.source])
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
    }

    @MainActor @Test func aHookSessionWithNoTerminalTakesThePlaceOfOneMuxyRowOfItsToolOnly() {
        let board = AgentBoard()
        board.replace(source: MuxyActivityWatcher.source, with: [
            "1": AgentBoard.Agent(state: .working, since: moment, tool: "claude", app: Muxy.bundleID, input: .muxy("1")),
            "2": AgentBoard.Agent(state: .working, since: moment, tool: "claude", app: Muxy.bundleID, input: .muxy("2")),
            "3": AgentBoard.Agent(state: .working, since: moment, tool: "codex", app: Muxy.bundleID, input: .muxy("3"))])
        // A Claude session whose hook started before it sent the terminal variables: one of Muxy's two Claude rows is it.
        board.replace(source: "hooks:claude", with: ["x": AgentBoard.Agent(state: .working, since: moment, tool: "claude")])
        #expect(board.counts == AgentBoard.Counts(working: 3))
        #expect(board.entries(now: moment).map(\.key).sorted() == ["hooks:claude|x", "muxy|2", "muxy|3"])
        // A hook that names another app is not in Muxy.
        board.replace(source: "hooks:claude", with: ["x": AgentBoard.Agent(state: .working, since: moment, tool: "claude", app: "com.apple.Terminal")])
        #expect(board.counts == AgentBoard.Counts(working: 4))
        // Nor is one that names another terminal.
        board.replace(source: "hooks:claude", with: ["x": AgentBoard.Agent(state: .working, since: moment, tool: "claude", input: .cmux("6F1B2C3D-0000"))])
        #expect(board.counts == AgentBoard.Counts(working: 4))
        // The old hook's session ends: Muxy's rows are all there again.
        board.clear(source: "hooks:claude")
        #expect(board.counts == AgentBoard.Counts(working: 3))
    }

    @MainActor @Test func aHookSessionInAnotherTerminalDoesNotHideMuxysSession() {
        let board = AgentBoard()
        board.replace(source: MuxyActivityWatcher.source, with: ["1": AgentBoard.Agent(state: .working, since: moment, input: .muxy("1"))])
        board.replace(source: "hooks:claude", with: ["x": AgentBoard.Agent(state: .working, since: moment, tool: "claude", input: .cmux("6F1B2C3D-0000"))])
        #expect(board.counts == AgentBoard.Counts(working: 2))
    }

    @MainActor @Test func aRowListedByMuxyIsGoneToWithoutAProcessButNeverTypedInto() throws {
        let agent = AgentBoard.Agent(state: .working, since: moment, tool: "claude", app: Muxy.bundleID, input: .muxy(big))
        let muxyRow = AgentRow(AgentBoard.Entry(source: MuxyActivityWatcher.source, id: big, agent: agent), transcript: nil)
        #expect(!muxyRow.offersInput && muxyRow.listedByTerminal && muxyRow.focusable)
        #expect(AgentFocus.plan(for: muxyRow, clis: TerminalCLIs()) == .terminal([.muxyFocus(session: big)], app: Muxy.bundleID))
        // Muxy's project folder travels with the click, for a session the desktop state has no pane for.
        var inProject = agent
        inProject.cwd = "/Users/namkun/Desktop/DEV"
        let projectRow = AgentRow(AgentBoard.Entry(source: MuxyActivityWatcher.source, id: big, agent: inProject), transcript: nil)
        #expect(AgentFocus.plan(for: projectRow, clis: TerminalCLIs()) == .terminal([.muxyFocus(session: big, folder: "/Users/namkun/Desktop/DEV")], app: Muxy.bundleID))
        // Why it can't be typed into is that Muxy lists it, not that its terminal is unknown.
        #expect(muxyRow.inputBlock == .listedOnly && muxyRow.blockReason?.contains("Muxy") == true)
        // A hook's row with the same input still needs its process verified.
        let hookRow = AgentRow(AgentBoard.Entry(source: "hooks:claude", id: "a", agent: agent), transcript: nil)
        #expect(!hookRow.listedByTerminal && AgentFocus.plan(for: hookRow, clis: TerminalCLIs()) == .app(Muxy.bundleID))
    }
}

/// The tool's answers, made up, and a record of what was asked.
private final class MadeUpMuxy: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (running: Bool, up: Bool, activity: Data?, projects: Data?) = (true, true, listing(), projectList)
    private var asked: [String] = []

    var running: Bool { get { with { $0.running } } set { with { $0.running = newValue } } }
    var up: Bool { get { with { $0.up } } set { with { $0.up = newValue } } }
    var activity: Data? { get { with { $0.activity } } set { with { $0.activity = newValue } } }
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return asked.filter { $0 == name }.count }

    @discardableResult
    private func with<T>(_ body: (inout (running: Bool, up: Bool, activity: Data?, projects: Data?)) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&values) }
    private func note(_ name: String) { lock.lock(); defer { lock.unlock() }; asked.append(name) }

    var backend: MuxyBackend {
        MuxyBackend(isRunning: { [self] in note("running"); return running }, serverUp: { [self] in note("status"); return up },
                    activity: { [self] in note("activity"); return activity }, projects: { [self] in note("projects"); return with { $0.projects } })
    }
}

private final class Notices { var lines: [String] = [] }

private final class Clock { var now = moment }

@MainActor
struct MuxyWatcherTests {
    private func makeWatcher(_ muxy: MadeUpMuxy, board: AgentBoard, notices: Bool = true, boardOn: Bool = true, front: String? = "com.apple.Terminal",
                             clock: Clock = Clock(), hooked: @escaping (MuxyEvent) -> Bool = { _ in false }) -> (MuxyActivityWatcher, Notices) {
        let watcher = MuxyActivityWatcher(board: board, backend: muxy.backend, now: { clock.now }, frontmost: { front }, hooked: hooked)
        watcher.noticesEnabled = notices
        watcher.wantsBoard = { boardOn }
        let shown = Notices()
        watcher.onNotice = { event, project, _ in shown.lines.append(event.notice(project: project) ?? "?") }
        return (watcher, shown)
    }

    /// One look, waited for.
    private func look(_ watcher: MuxyActivityWatcher) async {
        watcher.poll()
        await eventually { !watcher.looking }
    }

    @Test func nothingIsAskedOfMuxyThatIsNotRunning() async throws {
        let muxy = MadeUpMuxy()
        muxy.running = false
        let board = AgentBoard()
        let (watcher, _) = makeWatcher(muxy, board: board)
        watcher.poll()
        try await Task.sleep(for: .milliseconds(150))
        #expect(muxy.count("status") == 0 && muxy.count("activity") == 0 && board.counts.isEmpty)
    }

    @Test func aServerThatDoesNotAnswerIsNotStartedByAskingForItsActivity() async throws {
        let muxy = MadeUpMuxy()
        muxy.up = false
        let board = AgentBoard()
        let (watcher, _) = makeWatcher(muxy, board: board)
        watcher.poll()
        await eventually { muxy.count("status") == 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(muxy.count("activity") == 0 && muxy.count("projects") == 0)
    }

    @Test func nothingIsAskedWhenNeitherNoticesNorTheBoardWantIt() async throws {
        let muxy = MadeUpMuxy()
        let (watcher, _) = makeWatcher(muxy, board: AgentBoard(), notices: false, boardOn: false)
        watcher.poll()
        try await Task.sleep(for: .milliseconds(150))
        #expect(muxy.count("status") == 0 && muxy.count("activity") == 0)
    }

    @Test func agentsGoToTheBoardAndLeaveItWhenMuxyQuits() async throws {
        let muxy = MadeUpMuxy()
        muxy.activity = listing(agents: [agent(big, state: "working"), agent("2", provider: "Codex", state: "blocked"), agent("3", state: "idle")])
        let board = AgentBoard()
        let (watcher, _) = makeWatcher(muxy, board: board)
        await look(watcher)
        await eventually { board.counts == AgentBoard.Counts(working: 1, waiting: 1) }
        #expect(board.counts == AgentBoard.Counts(working: 1, waiting: 1))
        let entries = board.entries(now: moment)
        #expect(entries.map(\.source) == [MuxyActivityWatcher.source, MuxyActivityWatcher.source])
        #expect(entries.first { $0.id == big }?.agent.cwd == "/Users/namkun/Desktop/DEV")
        muxy.running = false
        watcher.poll()
        await eventually { board.counts.isEmpty }
        #expect(board.counts.isEmpty)
    }

    @Test func newEventsBecomeOneNoticeOfTheNewestAndHistoryIsNotReplayed() async throws {
        let muxy = MadeUpMuxy()
        muxy.activity = listing(revision: 1, events: [event("1", kind: "Completed")])
        let (watcher, notices) = makeWatcher(muxy, board: AgentBoard())
        await look(watcher)
        #expect(notices.lines.isEmpty)
        muxy.activity = listing(revision: 3, events: [event("3", provider: "Cursor", kind: "Completed", timestamp: 1_790_000_030), event("2", kind: "Attention", timestamp: 1_790_000_020),
                                                      event("1", kind: "Completed")])
        let asked = muxy.count("activity")
        watcher.poll()
        await eventually { muxy.count("activity") > asked && !notices.lines.isEmpty }
        #expect(notices.lines == ["Cursor in DEV finished"])
    }

    @Test func noNoticeWhileMuxyIsInFrontOrForAToolWhoseHookIsConnectedOrWhenNoticesAreOff() async throws {
        for (front, hooked, on) in [(Muxy.bundleID as String?, false, true), ("com.apple.Terminal", true, true), ("com.apple.Terminal", false, false)] {
            let muxy = MadeUpMuxy()
            muxy.activity = listing(revision: 1)
            let (watcher, notices) = makeWatcher(muxy, board: AgentBoard(), notices: on, boardOn: true, front: front, hooked: { _ in hooked })
            await look(watcher)
            muxy.activity = listing(revision: 2, events: [event("9", kind: "Attention")])
            let asked = muxy.count("activity")
            watcher.poll()
            await eventually { muxy.count("activity") > asked }
            try await Task.sleep(for: .milliseconds(150))
            #expect(notices.lines.isEmpty, "\(front ?? "nil") \(hooked) \(on)")
        }
    }

    @Test func theProjectNamesAreReadOnceAndAgainOnlyForAProjectTheyDontHaveOrWhenTheyAreOld() async throws {
        let muxy = MadeUpMuxy()
        let clock = Clock()
        muxy.activity = listing(revision: 1, agents: [agent(big)])
        let (watcher, _) = makeWatcher(muxy, board: AgentBoard(), clock: clock)
        await look(watcher)
        await look(watcher)
        #expect(muxy.count("projects") == 1)
        // A project the list doesn't have is looked for again, but not at every look.
        muxy.activity = listing(revision: 2, agents: [agent(big, project: "ffffffffffffffffffffffffffffffff")])
        clock.now = clock.now.addingTimeInterval(2)
        await look(watcher)
        #expect(muxy.count("projects") == 1)
        clock.now = clock.now.addingTimeInterval(MuxyActivityWatcher.unknownProjectRetry)
        await look(watcher)
        #expect(muxy.count("projects") == 2)
        // The names are read again once they are old, whether or not anything is missing.
        muxy.activity = listing(revision: 3, agents: [agent(big)])
        clock.now = clock.now.addingTimeInterval(MuxyActivityWatcher.projectsLifetime + 1)
        await look(watcher)
        #expect(muxy.count("projects") == 3)
    }

    /// It reads the sources and nothing of the main actor, which every other test of the suite waits for while it does.
    @Test nonisolated func muxyIsNeverToldAnythingEventsAreNotAcknowledgedAndNoInputIsSent() throws {
        // The backend can only read, and the tool is never run with `ack`, `send` or `create`.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Nunsseop/MuxyNotifications.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for forbidden in ["\"ack\"", "\"send\"", "\"send-keys\"", "\"create\""] {
            #expect(!text.contains(forbidden), Comment(rawValue: forbidden))
        }
        // Nothing of Muxy 1's text socket or notification file is left anywhere in the app.
        let sources = source.deletingLastPathComponent()
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let code = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for old in ["switch-project|", "switch-tab|", "switch-worktree|", "Muxy/notifications.json", "muxy.sock"] {
                #expect(!code.contains(old) || file == "MuxyNotifications.swift", Comment(rawValue: "\(file): \(old)"))
            }
        }
        #expect(text.contains(#"["activity", "list", "--json"]"#) && text.contains(#"["project", "list", "--json"]"#) && text.contains(#"["server", "status", "--json"]"#))
    }
}
