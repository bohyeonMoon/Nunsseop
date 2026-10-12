import Foundation
import Testing
@testable import Nunsseop

/// A home with Claude Code's and Codex's session files, made up for the tests.
private final class Home {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-recent-\(UUID().uuidString.prefix(8))")
    let now: Date
    private let files = FileManager.default

    init(now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        self.now = now
        try? files.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? files.removeItem(at: url) }

    /// A real folder to have conversations in.
    func folder(_ name: String) -> String {
        let path = url.appendingPathComponent("work/\(name)").path
        try? files.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data(), as: UTF8.self)
    }

    @discardableResult
    private func write(_ lines: [String], to path: String, ago: TimeInterval) -> URL {
        let file = url.appendingPathComponent(path)
        try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try? files.setAttributes([.modificationDate: now.addingTimeInterval(-ago)], ofItemAtPath: file.path)
        return file
    }

    /// A Claude Code session: a user line (of the `entrypoint`), what it was asked last and the lines in `extra`.
    @discardableResult
    func claude(_ id: String, cwd: String, ago: TimeInterval = 600, prompt: String? = "do the thing", entrypoint: String? = "cli",
                user: Bool = true, extra: [String] = [], project: String = "-Users-me-work") -> URL {
        var lines = [line(["type": "queue-operation", "operation": "enqueue"]), line(["type": "summary", "cwd": cwd])]
        if user {
            var object: [String: Any] = ["type": "user", "cwd": cwd, "message": ["role": "user", "content": "hello"]]
            object["entrypoint"] = entrypoint
            lines.append(line(object))
        }
        lines += extra
        if let prompt { lines.append(line(["type": "last-prompt", "lastPrompt": prompt, "leafUuid": "x", "sessionId": id])) }
        return write(lines, to: ".claude/projects/\(project)/\(id).jsonl", ago: ago)
    }

    func claudeTitle(_ type: String, key: String, _ value: String) -> String { line(["type": type, key: value, "sessionId": "s"]) }

    @discardableResult
    func codex(_ id: String, cwd: String, ago: TimeInterval = 600, source: Any = "cli", originator: String = "codex-tui",
               startedAgo: TimeInterval? = nil) -> URL {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        let moment = now.addingTimeInterval(-(startedAgo ?? ago))
        day.dateFormat = "yyyy/MM/dd"
        let folder = day.string(from: moment)
        day.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let meta = line(["type": "session_meta", "payload": ["id": id, "cwd": cwd, "originator": originator, "source": source]])
        return write([meta], to: ".codex/sessions/\(folder)/rollout-\(day.string(from: moment))-\(id).jsonl", ago: ago)
    }

    func codexName(_ id: String, _ name: String) {
        let index = url.appendingPathComponent(".codex/session_index.jsonl")
        try? files.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: index, encoding: .utf8)) ?? ""
        try? (existing + line(["id": id, "thread_name": name, "updated_at": "2026-10-01T00:00:00Z"]) + "\n").write(to: index, atomically: true, encoding: .utf8)
    }

    func list(_ scanner: inout RecentConversations, excluding open: Set<String> = []) -> [RecentConversation] {
        scanner.list(home: url, excluding: open, now: now, scratch: [])
    }

    func list(excluding open: Set<String> = []) -> [RecentConversation] {
        var scanner = RecentConversations()
        return list(&scanner, excluding: open)
    }
}

private func id(_ n: Int) -> String { String(format: "5f0c2d1e-0000-4000-8000-%012d", n) }

struct RecentConversationTests {
    @Test func theMostRecentFiveFromTheLastWeekNewestFirst() {
        let home = Home()
        let cwd = home.folder("api")
        for n in 1...6 { home.claude(id(n), cwd: cwd, ago: Double(n) * 3_600) }
        home.codex("01a130c4-3953-7f71-bc99-b8a6d37a5338", cwd: cwd, ago: 90 * 60)
        // Seven days is the limit.
        home.claude(id(8), cwd: cwd, ago: 7 * 86_400 + 60)
        home.claude(id(9), cwd: cwd, ago: 6 * 86_400)
        let found = home.list()
        #expect(found.count == RecentConversations.limit)
        #expect(found.map(\.session) == [id(1), "01a130c4-3953-7f71-bc99-b8a6d37a5338", id(2), id(3), id(4)])
        #expect(found.map(\.kind) == [.claude, .codex, .claude, .claude, .claude])
        #expect(found.allSatisfy { $0.cwd == cwd })
        // The week's end is in the list when there is room.
        let few = Home()
        let folder = few.folder("api")
        few.claude(id(1), cwd: folder, ago: 6 * 86_400)
        few.claude(id(2), cwd: folder, ago: 7 * 86_400 + 60)
        #expect(few.list().map(\.session) == [id(1)])
    }

    @Test func sessionsThatAreOpenAreLeftOutAnyCase() {
        let home = Home()
        let cwd = home.folder("api")
        home.claude(id(1), cwd: cwd, ago: 60)
        home.claude(id(2), cwd: cwd, ago: 120)
        home.codex("01A130C4-3953-7F71-BC99-B8A6D37A5338", cwd: cwd, ago: 180)
        let open: Set<String> = [id(1), "01a130c4-3953-7f71-bc99-b8a6d37a5338"]
        #expect(home.list(excluding: open).map(\.session) == [id(2)])
    }

    @Test func aFolderThatIsGoneOrScratchIsLeftOut() {
        let home = Home()
        home.claude(id(1), cwd: home.url.appendingPathComponent("work/gone").path, ago: 60)
        home.claude(id(2), cwd: "relative/path", ago: 120)
        home.claude(id(3), cwd: home.folder("kept"), ago: 180)
        #expect(home.list().map(\.session) == [id(3)])
        // The scratch folders of tools.
        for path in ["/tmp", "/tmp/x", "/private/tmp/work", "/var/folders/ab/cd/T/x", "/private/var/folders/ab"] {
            #expect(!RecentConversations.isResumableFolder(path))
        }
        #expect(!RecentConversations.isResumableFolder("/tmpfiles-nope"))
        #expect(RecentConversations.isResumableFolder("/usr"))
        #expect(RecentConversations.isResumableFolder("/private/var"))
        // By default the home's own folders under /var/folders are scratch too.
        var scanner = RecentConversations()
        #expect(scanner.list(home: home.url, excluding: [], now: home.now).isEmpty)
    }

    @Test func aClaudeSessionNeedsAPromptOfTheUsersAndIsNotRunByAProgram() {
        let home = Home()
        let cwd = home.folder("api")
        home.claude(id(1), cwd: cwd, ago: 60, prompt: nil, user: false)
        home.claude(id(2), cwd: cwd, ago: 120, entrypoint: "sdk-py")
        home.claude(id(3), cwd: cwd, ago: 130, entrypoint: "sdk-cli")
        home.claude(id(4), cwd: cwd, ago: 140, prompt: nil)
        home.claude(id(5), cwd: cwd, ago: 150, prompt: "from the tail", user: false)
        home.claude(id(6), cwd: cwd, ago: 160, entrypoint: nil)
        // A subagent's file lives in a subfolder and isn't a conversation.
        home.claude("subagents/agent-\(id(7))", cwd: cwd, ago: 30)
        #expect(home.list().map(\.session) == [id(4), id(5), id(6)])
    }

    @Test func aSidechainsFolderIsNotTheSessions() {
        let home = Home()
        let cwd = home.folder("api")
        let side = #"{"type":"user","isSidechain":true,"cwd":"/elsewhere","entrypoint":"sdk-cli"}"#
        home.claude(id(1), cwd: cwd, extra: [side])
        let file = home.url.appendingPathComponent(".claude/projects/-Users-me-work/\(id(1)).jsonl")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (side + "\n" + text).write(to: file, atomically: true, encoding: .utf8)
        #expect(home.list().map(\.cwd) == [cwd])
    }

    @Test func theTitleIsTheNameThenTheLastPromptThenTheFolder() {
        let home = Home()
        let cwd = home.folder("api")
        home.claude(id(1), cwd: cwd, ago: 60, extra: [home.claudeTitle("ai-title", key: "aiTitle", "Auto title"),
                                                       home.claudeTitle("custom-title", key: "customTitle", "My name")])
        home.claude(id(2), cwd: cwd, ago: 120, prompt: "  fix\nthe   login\tbug  ")
        home.claude(id(3), cwd: cwd, ago: 180, prompt: nil)
        home.claude(id(4), cwd: cwd, ago: 240, prompt: String(repeating: "x", count: 200))
        let found = home.list()
        #expect(found.map(\.title) == ["My name", "fix the login bug", "api", String(repeating: "x", count: 80)])
        #expect(found[0].name == "My name" && found[0].prompt == "do the thing")
        #expect(found[2].name == nil && found[2].prompt == nil)
    }

    @Test func onlyCodexSessionsStartedFromItsCommandLineAreOffered() {
        let home = Home()
        let cwd = home.folder("api")
        home.codex("01a130c4-0000-7f71-bc99-000000000001", cwd: cwd, ago: 60, source: "cli", originator: "codex-tui")
        home.codex("01a130c4-0000-7f71-bc99-000000000002", cwd: cwd, ago: 120, source: "exec", originator: "codex_exec")
        home.codex("01a130c4-0000-7f71-bc99-000000000003", cwd: cwd, ago: 180, source: "vscode", originator: "Codex Desktop")
        home.codex("01a130c4-0000-7f71-bc99-000000000004", cwd: cwd, ago: 240, source: ["subagent": "review"], originator: "codex-tui")
        home.codex("01a130c4-0000-7f71-bc99-000000000005", cwd: cwd, ago: 300, source: "cli")
        home.codexName("01a130c4-0000-7f71-bc99-000000000001", "old name")
        home.codexName("01a130c4-0000-7f71-bc99-000000000001", "refactor\nthe parser")
        let found = home.list()
        #expect(found.map(\.session) == ["01a130c4-0000-7f71-bc99-000000000001", "01a130c4-0000-7f71-bc99-000000000005"])
        // The last line for a session wins; one without a name shows its folder.
        #expect(found.map(\.title) == ["refactor the parser", "api"])
    }

    @Test func codexFilesOlderThanAWeekAreLeftOut() {
        let home = Home()
        let cwd = home.folder("api")
        home.codex("01a130c4-0000-7f71-bc99-000000000001", cwd: cwd, ago: 2 * 86_400)
        home.codex("01a130c4-0000-7f71-bc99-000000000002", cwd: cwd, ago: 9 * 86_400)
        #expect(home.list().map(\.session) == ["01a130c4-0000-7f71-bc99-000000000001"])
    }

    @Test func aCodexSessionResumedThisWeekIsOfferedWhereverItsDayFolderIs() {
        let home = Home()
        let cwd = home.folder("api")
        home.codex("01a130c4-0000-7f71-bc99-000000000001", cwd: cwd, ago: 3_600, startedAgo: 20 * 86_400)
        home.codex("01a130c4-0000-7f71-bc99-000000000002", cwd: cwd, ago: 12 * 86_400, startedAgo: 20 * 86_400)
        #expect(home.list().map(\.session) == ["01a130c4-0000-7f71-bc99-000000000001"])
    }

    @Test func automationTranscriptsDontHideTheConversationsBehindThem() {
        let home = Home()
        let cwd = home.folder("api")
        for n in 1...100 { home.claude(id(n), cwd: cwd, ago: 60 + Double(n), entrypoint: "sdk-cli") }
        for n in 101...103 { home.claude(id(n), cwd: cwd, ago: 3_600 + Double(n)) }
        #expect(home.list().map(\.session) == [id(101), id(102), id(103)])
    }

    @Test func unsafeNamesAreNotOffered() {
        let home = Home()
        let cwd = home.folder("api")
        home.claude("short", cwd: cwd)
        home.claude("5f0c2d1e;touch-x-0000", cwd: cwd)
        home.claude("5f0c2d1e 0000 4000", cwd: cwd)
        home.claude(id(1), cwd: cwd)
        let broken = home.url.appendingPathComponent(".codex/sessions/2026/10/01/rollout-2026-10-01T00-00-00-not-a-session.jsonl")
        try? FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{}\n".utf8).write(to: broken)
        #expect(home.list().map(\.session) == [id(1)])
    }

    @Test func aRepeatedScanRereadsOnlyWhatChanged() throws {
        let home = Home()
        let cwd = home.folder("api")
        let file = home.claude(id(1), cwd: cwd, ago: 60)
        var scanner = RecentConversations()
        #expect(home.list(&scanner).first?.title == "do the thing")
        // A name that is appended later is picked up once the file changed.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((home.claudeTitle("custom-title", key: "customTitle", "Renamed") + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: home.now.addingTimeInterval(-30)], ofItemAtPath: file.path)
        #expect(home.list(&scanner).first?.title == "Renamed")
        #expect(home.list(&scanner).first?.title == "Renamed")
        // A file that is gone is gone.
        try FileManager.default.removeItem(at: file)
        #expect(home.list(&scanner).isEmpty)
    }

    @Test func aMissingHomeHasNothing() {
        #expect(Home().list().isEmpty)
    }
}

struct RecentConversationRowTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func conversation(_ kind: AgentKind = .claude, name: String? = nil, prompt: String? = nil, ago: TimeInterval = 3 * 3_600 + 60,
                              cwd: String = "/Users/me/Projects/nunsseop") -> RecentConversation {
        RecentConversation(kind: kind, session: id(1), cwd: cwd, modified: now.addingTimeInterval(-ago), name: name, prompt: prompt)
    }

    @Test func titleAndDetails() {
        let named = conversation(name: "Resume list", prompt: "ask")
        #expect(named.title == "Resume list" && named.details(now: now) == ["nunsseop", "Claude Code", "3h ago"])
        let asked = conversation(.codex, prompt: "fix the bug", ago: 40)
        #expect(asked.title == "fix the bug" && asked.details(now: now) == ["nunsseop", "Codex", "<1m ago"])
        // The folder is the title, so it isn't said twice.
        let plain = conversation(ago: 2 * 86_400 + 5)
        #expect(plain.title == "nunsseop" && plain.details(now: now) == ["Claude Code", "2d ago"])
        let same = conversation(name: "Nunsseop")
        #expect(same.details(now: now) == ["Claude Code", "3h ago"])
        #expect(conversation().id == "claude|\(id(1))" && conversation(.codex).id == "codex|\(id(1))")
        #expect(conversation().folder == "nunsseop" && conversation().tool == "Claude Code")
    }
}

@MainActor
struct RecentConversationModelTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(eventDeadline)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @Test func recentConversationsAreListedWhileTheTabShowsAndLeaveOutWhatIsOnTheBoard() async throws {
        let home = Home(now: .now)
        let cwd = home.folder("api")
        home.claude(id(1), cwd: cwd, ago: 60)
        home.claude(id(2), cwd: cwd, ago: 120)
        let board = AgentBoard()
        let model = AgentsTabModel(board: board, home: { home.url }, isConnected: { true }, scratch: [])
        #expect(model.recent.isEmpty)
        model.isShowing = true
        #expect(await eventually { model.recent.count == 2 })
        #expect(model.recent.map(\.session) == [id(1), id(2)])

        // A session that starts leaves the list.
        board.replace(source: "hooks:claude", with: ["x": AgentBoard.Agent(state: .working, since: .now, tool: "claude", session: id(1).uppercased())])
        #expect(await eventually { model.recent.map(\.session) == [id(2)] })
        model.isShowing = false
        board.clear(source: "hooks:claude")
        #expect(model.recent.map(\.session) == [id(2)])
    }

    @Test func clickingARecentRowResumesIt() {
        var resumed: [String] = []
        let model = AgentsTabModel(board: AgentBoard(), isConnected: { true }, onResume: { resumed.append($0.session) })
        model.resume(RecentConversation(kind: .claude, session: id(3), cwd: "/usr", modified: .now))
        #expect(resumed == [id(3)])
    }

    @Test func theEmptyMessageWaitsForTheFirstScan() async {
        let home = Home(now: .now)
        let model = AgentsTabModel(board: AgentBoard(), home: { home.url }, isConnected: { true }, scratch: [])
        model.isShowing = true
        #expect(!model.recentLoaded && !model.showsEmptyMessage)
        #expect(await eventually { model.recentLoaded })
        #expect(model.showsEmptyMessage)
        // Something to show instead of it.
        home.claude(id(1), cwd: home.folder("api"), ago: 60)
        model.refresh()
        #expect(await eventually { model.recent.count == 1 })
        #expect(!model.showsEmptyMessage)
    }

    @Test func aRepeatClickOnTheSameRowOpensItOnce() {
        var resumed: [String] = []
        let model = AgentsTabModel(board: AgentBoard(), isConnected: { true }, onResume: { resumed.append($0.id) })
        let now = Date.now
        let first = RecentConversation(kind: .claude, session: id(1), cwd: "/usr", modified: now)
        let second = RecentConversation(kind: .codex, session: id(1), cwd: "/usr", modified: now)
        let other = RecentConversation(kind: .claude, session: id(2), cwd: "/usr", modified: now)
        model.resume(first, now: now)
        model.resume(first, now: now.addingTimeInterval(1))
        model.resume(first, now: now.addingTimeInterval(AgentsTabModel.openingWindow - 1))
        #expect(resumed == [first.id])
        // Another conversation, even of the other tool with the same id, is not held back.
        model.resume(other, now: now.addingTimeInterval(2))
        model.resume(second, now: now.addingTimeInterval(3))
        #expect(resumed == [first.id, other.id, second.id])
        // Once the window is over a click counts again.
        model.resume(first, now: now.addingTimeInterval(AgentsTabModel.openingWindow + 1))
        #expect(resumed == [first.id, other.id, second.id, first.id])
    }

    @Test func theDemoShowsTwoRecentRows() {
        let model = AgentsTabModel(board: AgentBoard(), isConnected: { true })
        model.fixedRecent = AgentBoard.demoRecent()
        model.refresh()
        #expect(model.recent.count == 2)
        let now = Date.now
        #expect(model.recent[0].title == "Resume list" && model.recent[0].details(now: now) == ["nunsseop", "Claude Code", "3h ago"])
        #expect(model.recent[1].title == "ios-app" && model.recent[1].details(now: now) == ["Codex", "1d ago"])
    }
}
