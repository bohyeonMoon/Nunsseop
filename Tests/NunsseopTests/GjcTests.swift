import Foundation
import Testing
@testable import Nunsseop

/// The gjc processes of a made-up machine: how many run in each folder.
private final class Processes: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: Int] = [:]
    func set(_ folder: String, _ count: Int) {
        lock.lock(); defer { lock.unlock() }
        // As the system reports a folder: links resolved.
        table[URL(fileURLWithPath: folder).resolvingSymlinksInPath().path] = count == 0 ? nil : count
    }
    var all: [String: Int] { lock.lock(); defer { lock.unlock() }; return table }
}

/// gjc's session files and the state files of its sessions, made up in a scratch home.
private final class GjcHome {
    let processes = Processes()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-gjc-\(UUID().uuidString.prefix(8))")
    var now: Date
    private let files = FileManager.default

    init(now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        self.now = now
        try? files.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? files.removeItem(at: url) }

    func folder(_ name: String) -> String {
        let path = url.appendingPathComponent("work/\(name)").path
        try? files.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// The session file that tells where the session lives; `ago` is its age.
    func sessionFile(_ id: String, cwd: String, ago: TimeInterval = 600) {
        let file = url.appendingPathComponent(".gjc/agent/sessions/v2-hash/\(PiFixture.stamp(now.addingTimeInterval(-ago)))_\(id).jsonl")
        try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((PiFixture.header(id: id, cwd: cwd, title: "A title") + "\n").utf8).write(to: file)
        try? files.setAttributes([.modificationDate: now.addingTimeInterval(-ago)], ofItemAtPath: file.path)
    }

    /// `<cwd>/.gjc/_session-<id>/runtime/runtime-state.json`, beating `heartbeat` seconds ago.
    func state(_ id: String, cwd: String, state: String = "running", live: Bool = true, ready: Bool = false, heartbeat: TimeInterval = 0.5,
               fileAge: TimeInterval? = nil, directory: String? = nil, stateCwd: String? = nil) {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = ["schema_version": 1, "session_id": id, "state": state, "ready_for_input": ready, "live": live,
                                     "updated_at": format.string(from: now.addingTimeInterval(-heartbeat)), "cwd": stateCwd ?? cwd, "reason": NSNull()]
        let file = URL(fileURLWithPath: cwd).appendingPathComponent(".gjc/\(directory ?? "_session-\(id)")/runtime/runtime-state.json")
        try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(PiFixture.line(object).utf8).write(to: file)
        try? files.setAttributes([.modificationDate: now.addingTimeInterval(-(fileAge ?? heartbeat))], ofItemAtPath: file.path)
    }

    /// A gjc process in `cwd` (as many as `count`).
    func run(in cwd: String, _ count: Int = 1) { processes.set(cwd, count) }
    var scanner: GjcScanner { let processes = processes; return GjcScanner(runningFolders: { processes.all }) }

    func scan(_ scanner: inout GjcScanner) -> [GjcSession] { scanner.scan(home: url, now: now) }
    func scan() -> [GjcSession] { var scanner = scanner; return scan(&scanner) }
}

private func gid(_ n: Int) -> String { PiFixture.id(n) }

struct GjcScannerTests {
    @Test func aSessionWithAProcessInItsFolderIsFoundWhereItsSessionFileSays() {
        let home = GjcHome()
        let cwd = home.folder("api")
        home.sessionFile(gid(1), cwd: cwd)
        home.run(in: cwd)
        home.state(gid(1), cwd: cwd, state: "needs_user_input")
        #expect(home.scan() == [GjcSession(id: gid(1), cwd: cwd, state: "needs_user_input", ready: false)])
        home.state(gid(1), cwd: cwd, state: "ready_for_input", ready: true)
        #expect(home.scan() == [GjcSession(id: gid(1), cwd: cwd, state: "ready_for_input", ready: true)])
        // The folder in the state file is the session's own (it may have moved on from the one the file began in).
        home.state(gid(1), cwd: cwd, stateCwd: "/Users/me/elsewhere")
        #expect(home.scan().first?.cwd == "/Users/me/elsewhere")
    }

    /// gjc writes the state file when the state changes: a turn of minutes has the time of its start, and a session at its
    /// prompt is `completed` with `live: false` (as in the files gjc 0.18.5 leaves).
    @Test func aStateFileThatIsNotBeatingIsStillASessionWhileItsProcessRuns() {
        let home = GjcHome()
        let cwd = home.folder("api"), other = home.folder("web")
        home.sessionFile(gid(1), cwd: cwd)
        home.sessionFile(gid(2), cwd: other)
        home.run(in: cwd)
        home.run(in: other)
        home.state(gid(1), cwd: cwd, state: "running", heartbeat: 20 * 60, fileAge: 20 * 60)
        home.state(gid(2), cwd: other, state: "completed", live: false, ready: true, heartbeat: 3_600, fileAge: 3_600)
        #expect(home.scan().map(\.state) == ["running", "completed"])
        #expect(home.scan().map(\.ready) == [false, true])
    }

    @Test func whatHasNoProcessOrIsNotASessionIsNotListed() {
        let home = GjcHome()
        let cwd = home.folder("api"), gone = home.folder("gone")
        home.sessionFile(gid(1), cwd: cwd)
        home.sessionFile(gid(9), cwd: gone)
        home.run(in: cwd)
        // A crash that left `live: true` and a finished one, with no process in their folder.
        home.state(gid(9), cwd: gone, state: "running")
        home.state(gid(10), cwd: gone, state: "completed", live: false, ready: true)
        // Ended in an error, a subagent's directory, an unsafe id, a directory that is no session's.
        home.state(gid(3), cwd: cwd, state: "errored", live: false)
        home.state(gid(6), cwd: cwd, directory: "_session-%5B%22subagent-canonical%22%2C%22\(gid(6))%22%5D")
        home.state("../../etc", cwd: cwd, directory: "_session-x")
        home.state(gid(7), cwd: cwd, directory: "notes")
        #expect(home.scan().isEmpty)
        home.state(gid(8), cwd: cwd)
        #expect(home.scan().map(\.id) == [gid(8)])
        // No process anywhere: nothing, whatever the files say.
        home.run(in: cwd, 0)
        #expect(home.scan().isEmpty)
    }

    @Test func aFolderHasAsManySessionsAsProcessesAndTheyAreTheNewestOnes() {
        let home = GjcHome()
        let cwd = home.folder("api")
        home.sessionFile(gid(1), cwd: cwd)
        // Left by earlier sessions, and the one open now (the newest).
        home.state(gid(1), cwd: cwd, state: "completed", live: false, ready: true, heartbeat: 7_200, fileAge: 7_200)
        home.state(gid(2), cwd: cwd, state: "completed", live: false, ready: true, heartbeat: 3_600, fileAge: 3_600)
        home.state(gid(3), cwd: cwd, state: "running", heartbeat: 30, fileAge: 30)
        home.run(in: cwd)
        #expect(home.scan().map(\.id) == [gid(3)])
        home.run(in: cwd, 2)
        #expect(home.scan().map(\.id) == [gid(2), gid(3)])
        // A state file older than the window is not an open session.
        home.state(gid(4), cwd: cwd, heartbeat: GjcScanner.window + 60, fileAge: GjcScanner.window + 60)
        home.run(in: cwd, 9)
        #expect(home.scan().map(\.id) == [gid(1), gid(2), gid(3)])
    }

    @Test func theProcessTableFindsAProcessNamedGjcByTheFolderItRunsIn() throws {
        // A copy of sleep named gjc (signed again, or macOS kills it): not gjc, and nothing of the user's is started.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-gjcproc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("gjc")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: link)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", link.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0, "codesign is needed to run a copy of a system tool")
        let process = Process()
        process.executableURL = link
        process.arguments = ["30"]
        process.currentDirectoryURL = folder
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let key = folder.resolvingSymlinksInPath().path
        var found: Int?
        for _ in 0..<20 where found == nil {
            found = GjcScanner.liveFolders()[key]
            if found == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        #expect(found == 1)
        process.terminate()
        process.waitUntilExit()
        #expect(GjcScanner.liveFolders()[key] == nil)
    }

    @Test func onlyTheFoldersOfRecentSessionFilesAreLookedIn() {
        let home = GjcHome()
        let recent = home.folder("recent"), old = home.folder("old"), unsafe = home.folder("unsafe")
        home.sessionFile(gid(1), cwd: recent, ago: GjcScanner.window - 60)
        home.sessionFile(gid(2), cwd: old, ago: GjcScanner.window + 60)
        home.sessionFile(gid(3), cwd: "relative/folder", ago: 60)
        home.state(gid(1), cwd: recent)
        home.state(gid(2), cwd: old)
        home.state(gid(3), cwd: unsafe)
        for folder in [recent, old, unsafe] { home.run(in: folder) }
        #expect(home.scan().map(\.id) == [gid(1)])
        #expect(GjcScanner.folder(inHeaderOf: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test func theFoldersAreListedAgainOnlyEveryFewSecondsAndWhenTheClockGoesBack() {
        let home = GjcHome()
        let first = home.folder("first"), second = home.folder("second")
        home.sessionFile(gid(1), cwd: first)
        home.state(gid(1), cwd: first)
        home.run(in: first)
        home.run(in: second)
        var scanner = home.scanner
        #expect(home.scan(&scanner).map(\.id) == [gid(1)])
        // A session in a new folder is found at the next listing, not before.
        home.sessionFile(gid(2), cwd: second)
        home.state(gid(2), cwd: second)
        home.now.addTimeInterval(GjcScanner.folderInterval - 1)
        home.state(gid(1), cwd: first)
        home.state(gid(2), cwd: second)
        #expect(home.scan(&scanner).map(\.id) == [gid(1)])
        home.now.addTimeInterval(1)
        home.state(gid(1), cwd: first)
        home.state(gid(2), cwd: second)
        #expect(home.scan(&scanner).map(\.id) == [gid(1), gid(2)])
        home.now.addTimeInterval(-3_600)
        home.sessionFile(gid(3), cwd: first, ago: 60)
        home.state(gid(3), cwd: first)
        home.state(gid(1), cwd: first)
        home.run(in: first, 2)
        #expect(home.scan(&scanner).map(\.id).contains(gid(3)))
    }

    @Test func noGjcMeansNoSessions() {
        #expect(GjcHome().scan().isEmpty)
    }
}

struct GjcTrackerTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func session(_ state: String, ready: Bool = false, id: String = gid(1)) -> GjcSession {
        GjcSession(id: id, cwd: "/Users/me/api", state: state, ready: ready)
    }

    @Test func aRunningSessionWorksAndOneThatNeedsTheUserWaits() {
        var tracker = GjcTracker()
        let working = tracker.agents(for: [session("running")], now: start)[gid(1)]
        #expect(working == AgentBoard.Agent(state: .working, since: start, finished: false, tool: "gjc", cwd: "/Users/me/api", session: gid(1)))
        let asking = tracker.agents(for: [session("needs_user_input")], now: start.addingTimeInterval(5))[gid(1)]
        #expect(asking?.state == .waiting && asking?.finished == false && asking?.since == start.addingTimeInterval(5) && asking?.idleFrom == nil)
        // Staying in a state keeps when it began.
        #expect(tracker.agents(for: [session("needs_user_input")], now: start.addingTimeInterval(9))[gid(1)]?.since == start.addingTimeInterval(5))
    }

    @Test func aTurnSeenToEndIsAFinishedHandThatTurnsIdleAfterTheDoneWindow() {
        var tracker = GjcTracker()
        _ = tracker.agents(for: [session("running")], now: start)
        let ended = start.addingTimeInterval(30)
        let done = tracker.agents(for: [session("ready_for_input", ready: true)], now: ended)[gid(1)]
        #expect(done?.state == .waiting && done?.finished == true && done?.since == ended && done?.idleFrom == ended.addingTimeInterval(Herdr.doneWindow))
        // The next poll finds it still at the prompt: it is the same hand, not a new one.
        let later = tracker.agents(for: [session("ready_for_input", ready: true)], now: ended.addingTimeInterval(60))[gid(1)]
        #expect(later == done)
        #expect(later?.effective(at: ended.addingTimeInterval(Herdr.doneWindow - 1)).state == .waiting)
        #expect(later?.effective(at: ended.addingTimeInterval(Herdr.doneWindow)).state == .idle)
        // "completed" while live is the same as ready.
        var other = GjcTracker()
        _ = other.agents(for: [session("running")], now: start)
        #expect(other.agents(for: [session("completed", ready: true)], now: ended)[gid(1)]?.finished == true)
        // A question answered and the turn done: it was asking, then ready.
        var asked = GjcTracker()
        _ = asked.agents(for: [session("needs_user_input")], now: start)
        #expect(asked.agents(for: [session("ready_for_input", ready: true)], now: ended)[gid(1)]?.finished == true)
    }

    @Test func aSessionFirstSeenAtItsPromptIsIdleNotAFinishedHand() {
        var tracker = GjcTracker()
        let idle = tracker.agents(for: [session("ready_for_input", ready: true)], now: start)[gid(1)]
        #expect(idle?.state == .idle && idle?.finished == false && idle?.idleFrom == nil)
        // Working again, then done: now it is a hand.
        _ = tracker.agents(for: [session("running")], now: start.addingTimeInterval(10))
        #expect(tracker.agents(for: [session("ready_for_input", ready: true)], now: start.addingTimeInterval(20))[gid(1)]?.finished == true)
    }

    @Test func aSessionThatGoesIsForgottenAndOneThatComesBackStartsOver() {
        var tracker = GjcTracker()
        _ = tracker.agents(for: [session("running"), session("running", id: gid(2))], now: start)
        let both = tracker.agents(for: [session("running", id: gid(2))], now: start.addingTimeInterval(5))
        #expect(Set(both.keys) == [gid(2)])
        // Back at its prompt after being gone: seen for the first time, so idle.
        #expect(tracker.agents(for: [session("ready_for_input", ready: true), session("running", id: gid(2))],
                               now: start.addingTimeInterval(10))[gid(1)]?.state == .idle)
        #expect(tracker.agents(for: [], now: start.addingTimeInterval(15)).isEmpty)
    }

    @Test func theRowsSayGjcAndTheFolder() {
        var tracker = GjcTracker()
        let agent = try! #require(tracker.agents(for: [session("running")], now: start)[gid(1)])
        let row = AgentRow(AgentBoard.Entry(source: "gjc", id: gid(1), agent: agent), transcript: AgentTranscript(model: "claude-sonnet-5", tokens: 18_277, name: "Sprint plan"))
        #expect(row.title == "Sprint plan" && row.metaParts == ["api", "gjc", "Sonnet 5"] && row.tokensLabel == "18k")
        #expect(AgentRow.transcriptKey(agent) == AgentTranscripts.Key(kind: .gjc, session: gid(1)))
        #expect(row.target == nil)
    }
}

@MainActor
struct GjcWatcherTests {
    private func watcher(_ home: GjcHome, board: AgentBoard, on: Bool = true) -> (GjcWatcher, () -> Date) {
        let box = ClockBox(home.now)
        let processes = home.processes
        return (GjcWatcher(board: board, isOn: { on }, home: home.url, now: { box.now }, runningFolders: { processes.all }), { box.now })
    }

    final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    @Test func aSessionCountsWhileOnAndLeavesWhenItsProcessIsGone() async {
        let home = GjcHome()
        let cwd = home.folder("api")
        home.sessionFile(gid(1), cwd: cwd)
        home.run(in: cwd)
        home.state(gid(1), cwd: cwd, state: "running")
        let board = AgentBoard()
        let (gjc, _) = watcher(home, board: board)
        gjc.poll()
        await eventually { board.counts == AgentBoard.Counts(working: 1) }
        let entry = board.entries(now: home.now).first
        #expect(entry?.source == "gjc" && entry?.agent.tool == "gjc" && entry?.agent.session == gid(1) && entry?.agent.cwd == cwd)
        // The process is gone: the state file may say what it likes (a crash leaves `running` behind).
        home.run(in: cwd, 0)
        gjc.poll()
        await eventually { board.counts.isEmpty }
        #expect(board.entries(now: home.now).isEmpty)
    }

    @Test func nothingIsReadWhileTheCountAndTheTabAreOffAndResetClearsTheBoard() async throws {
        let home = GjcHome()
        let cwd = home.folder("api")
        home.sessionFile(gid(1), cwd: cwd)
        home.run(in: cwd)
        home.state(gid(1), cwd: cwd)
        let board = AgentBoard()
        let (off, _) = watcher(home, board: board, on: false)
        off.poll()
        try await Task.sleep(for: .milliseconds(300))
        #expect(board.counts.isEmpty)
        let (gjc, _) = watcher(home, board: board)
        gjc.poll()
        await eventually { board.counts.working == 1 }
        gjc.reset()
        #expect(board.counts.isEmpty)
    }

    @Test func theBoardIsToldOnlyOfAChange() async throws {
        let home = GjcHome()
        let cwd = home.folder("api")
        home.sessionFile(gid(1), cwd: cwd)
        home.run(in: cwd)
        home.state(gid(1), cwd: cwd)
        let board = AgentBoard()
        let (gjc, _) = watcher(home, board: board)
        gjc.poll()
        await eventually { board.counts.working == 1 }
        let revision = board.revision
        for _ in 0..<3 {
            home.state(gid(1), cwd: cwd)
            gjc.poll()
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(board.revision == revision)
    }

    @Test func aMachineWithoutGjcIsLeftAlone() async throws {
        let home = GjcHome()
        let board = AgentBoard()
        let (gjc, _) = watcher(home, board: board)
        let revision = board.revision
        gjc.poll()
        try await Task.sleep(for: .milliseconds(200))
        #expect(board.revision == revision && board.counts.isEmpty)
    }
}
