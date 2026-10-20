import Foundation
import SQLite3
import Testing
@testable import Nunsseop

/// A home with Claude Code's and Codex's session files, made up for the tests. The week is 12 to 18 October 2026 in Seoul.
private final class RecapHome {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-recap-\(UUID().uuidString.prefix(8))")
    var calendar = Calendar(identifier: .gregorian)
    let monday: Date
    private let iso: ISO8601DateFormatter

    init() {
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone(identifier: "UTC")!
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// A Wednesday, in the week after.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))! }

    /// `day` 0 is that Monday and -7 the Monday before; `hour` and `minute` are Seoul time.
    func stamp(_ day: Int, _ hour: Int, _ minute: Int = 0, second: Int = 0) -> String {
        let start = calendar.date(byAdding: .day, value: day, to: monday)!
        return iso.string(from: calendar.date(bySettingHour: hour, minute: minute, second: second, of: start)!)
    }

    func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data(), as: UTF8.self)
    }

    @discardableResult
    func write(_ lines: [String], to path: String) -> URL {
        let file = url.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }

    func read() -> WeekRecap { WeekRecap.read(home: url, now: now, calendar: calendar) }

    // MARK: Claude Code

    func claudeLine(_ type: String = "user", session: String, cwd: String = "/Users/me/work/Nunsseop", at time: String, entrypoint: String? = nil,
                    content: [[String: Any]]? = nil, message: String? = nil, usage: [String: Int]? = nil) -> String {
        var object: [String: Any] = ["type": type, "sessionId": session, "cwd": cwd, "timestamp": time]
        if let entrypoint { object["entrypoint"] = entrypoint }
        var body: [String: Any] = [:]
        if let content { body["content"] = content }
        if let message { body["id"] = message }
        if let usage { body["usage"] = usage }
        if !body.isEmpty { object["message"] = body }
        return json(object)
    }

    func toolUse(_ name: String, id: String, input: [String: Any]) -> [[String: Any]] {
        [["type": "tool_use", "id": id, "name": name, "input": input]]
    }

    @discardableResult
    func claude(_ session: String, folder: String = "-Users-me-work-Nunsseop", _ lines: [String]) -> URL {
        write(lines, to: ".claude/projects/\(folder)/\(session).jsonl")
    }

    // MARK: Codex

    func codexMeta(_ id: String, cwd: String = "/Users/me/work/Server", at time: String) -> String {
        json(["timestamp": time, "type": "session_meta", "payload": ["id": id, "cwd": cwd, "source": "cli"]])
    }

    func codexLine(_ type: String = "event_msg", at time: String, payload: [String: Any] = ["type": "agent_message"]) -> String {
        json(["timestamp": time, "type": type, "payload": payload])
    }

    func codexTokens(at time: String, input: Int, cached: Int = 0, output: Int, total: Int) -> String {
        codexLine(at: time, payload: ["type": "token_count", "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output],
                                                                     "total_token_usage": ["total_tokens": total]]])
    }

    @discardableResult
    func codex(_ id: String, day: String = "2026/10/14", _ lines: [String]) -> URL {
        write(lines, to: ".codex/sessions/\(day)/rollout-\(day.replacingOccurrences(of: "/", with: "-"))T09-00-00-\(id).jsonl")
    }
}

private func minutes(_ value: Double) -> TimeInterval { value * 60 }

struct WeeklyRecapTests {
    @Test func workingTimeAddsGapsOfFiveMinutesOrLess() {
        let home = RecapHome()
        home.claude("s1", [home.claudeLine(session: "s1", at: home.stamp(0, 10, 0)),
                           home.claudeLine("assistant", session: "s1", at: home.stamp(0, 10, 3)),
                           // Exactly five minutes still counts, seventeen does not.
                           home.claudeLine(session: "s1", at: home.stamp(0, 10, 8)),
                           home.claudeLine("assistant", session: "s1", at: home.stamp(0, 10, 25)),
                           home.claudeLine(session: "s1", at: home.stamp(0, 10, 27))])
        let recap = home.read()
        #expect(recap.working == minutes(3 + 5 + 2))
        #expect(recap.longest?.duration == minutes(10))
    }

    @Test func theWeekRunsFromMondayToMondayInLocalTime() {
        let home = RecapHome()
        home.claude("s1", [home.claudeLine(session: "s1", at: home.stamp(-1, 23, 58)),
                           home.claudeLine(session: "s1", at: home.stamp(-1, 23, 59, second: 59)),
                           // Midnight Monday starts the week; a gap across it is not counted for either side.
                           home.claudeLine(session: "s1", at: home.stamp(0, 0, 0)),
                           home.claudeLine(session: "s1", at: home.stamp(0, 0, 2)),
                           home.claudeLine(session: "s1", at: home.stamp(6, 23, 58)),
                           home.claudeLine(session: "s1", at: home.stamp(6, 23, 59, second: 59)),
                           home.claudeLine(session: "s1", at: home.stamp(7, 0, 0)),
                           home.claudeLine(session: "s1", at: home.stamp(7, 1, 0))])
        let recap = home.read()
        #expect(recap.week == DateInterval(start: home.monday, end: home.calendar.date(byAdding: .day, value: 7, to: home.monday)!))
        #expect(recap.working == minutes(2) + minutes(1) + 59)
        #expect(recap.workingBefore == minutes(1) + 59)
        #expect(recap.days[0] == minutes(2))
        #expect(recap.days[6] == minutes(1) + 59)
        #expect(recap.sessions == 1)
    }

    @Test func aSessionOnlyInAnotherWeekIsNotCounted() {
        let home = RecapHome()
        home.claude("before", [home.claudeLine(session: "before", at: home.stamp(-3, 10)), home.claudeLine(session: "before", at: home.stamp(-3, 10, 4))])
        home.claude("after", [home.claudeLine(session: "after", at: home.stamp(8, 10)), home.claudeLine(session: "after", at: home.stamp(8, 10, 4))])
        home.codex("old", day: "2026/09/20", [home.codexMeta("old", at: home.stamp(-22, 9)), home.codexLine(at: home.stamp(-22, 9, 2))])
        let recap = home.read()
        #expect(recap.isEmpty && recap.sessions == 0 && recap.working == 0)
        #expect(recap.workingBefore == minutes(4))
        #expect(recap.busiestDay == nil && recap.longest == nil && recap.topProject == nil)
    }

    @Test func sessionsAreCountedPerTool() {
        let home = RecapHome()
        home.claude("a", [home.claudeLine(session: "a", at: home.stamp(1, 9))])
        home.claude("b", [home.claudeLine(session: "b", at: home.stamp(2, 9))])
        home.codex("c", [home.codexMeta("c", at: home.stamp(2, 10)), home.codexLine(at: home.stamp(2, 10, 1))])
        let recap = home.read()
        #expect(recap.claudeSessions == 2 && recap.codexSessions == 1 && recap.sessions == 3)
        #expect(!recap.isEmpty)
    }

    @Test func aSessionKeptInSeveralFilesIsOneSession() {
        // A subagent's file shares the session id.
        let home = RecapHome()
        home.claude("a", [home.claudeLine(session: "a", at: home.stamp(1, 9)), home.claudeLine(session: "a", at: home.stamp(1, 9, 2))])
        home.write([home.claudeLine(session: "a", at: home.stamp(1, 9, 1)), home.claudeLine(session: "a", at: home.stamp(1, 9, 3))],
                   to: ".claude/projects/-Users-me-work-Nunsseop/a/subagents/agent-1.jsonl")
        let recap = home.read()
        #expect(recap.claudeSessions == 1)
        #expect(recap.working == minutes(3))
    }

    @Test func programsStartedWithTheSDKAreLeftOut() {
        let home = RecapHome()
        home.claude("sdk", [home.claudeLine(session: "sdk", at: home.stamp(1, 9), entrypoint: "sdk-cli"),
                            home.claudeLine("assistant", session: "sdk", at: home.stamp(1, 9, 2), message: "m1", usage: ["output_tokens": 999])])
        home.claude("cli", [home.claudeLine(session: "cli", at: home.stamp(1, 11), entrypoint: "cli"),
                            home.claudeLine("assistant", session: "cli", at: home.stamp(1, 11, 1), message: "m2", usage: ["output_tokens": 7])])
        let recap = home.read()
        #expect(recap.claudeSessions == 1 && recap.working == minutes(1) && recap.claudeTokens == 7)
    }

    @Test func tokensAreAddedPerToolWithEachResponseOnce() {
        let home = RecapHome()
        home.claude("a", [home.claudeLine("assistant", session: "a", at: home.stamp(1, 9), message: "m1", usage: ["input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 25, "cache_read_input_tokens": 9_000]),
                          // The same response logged again, one from the week before and one after the week.
                          home.claudeLine("assistant", session: "a", at: home.stamp(1, 9, 1), message: "m1", usage: ["input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 25]),
                          home.claudeLine("assistant", session: "a", at: home.stamp(-1, 9), message: "m0", usage: ["output_tokens": 1_000]),
                          home.claudeLine("assistant", session: "a", at: home.stamp(7, 9), message: "m9", usage: ["output_tokens": 1_000])])
        home.codex("c", [home.codexMeta("c", at: home.stamp(2, 10)),
                         // Cached input is left out, as in the usage on the AI tab; a repeated total is one response.
                         home.codexTokens(at: home.stamp(2, 10, 1), input: 1_000, cached: 400, output: 50, total: 1_050),
                         home.codexTokens(at: home.stamp(2, 10, 2), input: 1_000, cached: 400, output: 50, total: 1_050),
                         home.codexTokens(at: home.stamp(2, 10, 3), input: 200, output: 10, total: 1_260)])
        let recap = home.read()
        #expect(recap.claudeTokens == 175)
        #expect(recap.codexTokens == 650 + 210)
        #expect(recap.tokens == 175 + 860)
    }

    @Test func claudeEditsCountLinesAddedAndRemoved() {
        let home = RecapHome()
        home.claude("a", [
            home.claudeLine("assistant", session: "a", at: home.stamp(1, 9),
                            content: home.toolUse("Edit", id: "t1", input: ["file_path": "/p/A.swift", "old_string": "keep\nold1\nold2", "new_string": "keep\nnew1\nnew2\nnew3"])),
            home.claudeLine("assistant", session: "a", at: home.stamp(1, 9, 1),
                            content: home.toolUse("MultiEdit", id: "t2", input: ["file_path": "/p/B.swift", "edits": [["old_string": "x", "new_string": "y"], ["old_string": "gone\n", "new_string": ""]]])),
            home.claudeLine("assistant", session: "a", at: home.stamp(1, 9, 2),
                            content: home.toolUse("Write", id: "t3", input: ["file_path": "/p/C.swift", "content": "one\ntwo\nthree\n"])),
            // The same call logged twice, a tool that isn't an edit, and an edit outside the week.
            home.claudeLine("assistant", session: "a", at: home.stamp(1, 9, 3),
                            content: home.toolUse("Write", id: "t3", input: ["file_path": "/p/C.swift", "content": "one\ntwo\nthree\n"])),
            home.claudeLine("assistant", session: "a", at: home.stamp(1, 9, 4), content: home.toolUse("Read", id: "t4", input: ["file_path": "/p/D.swift"])),
            home.claudeLine("assistant", session: "a", at: home.stamp(-1, 9), content: home.toolUse("Write", id: "t5", input: ["file_path": "/p/E.swift", "content": "a\nb"])),
            home.claudeLine("assistant", session: "a", at: home.stamp(2, 9),
                            content: home.toolUse("Edit", id: "t6", input: ["file_path": "/p/A.swift", "old_string": "new1", "new_string": "newer1"])),
        ])
        let recap = home.read()
        // Edit: +3 -2; MultiEdit: +1 -2; Write: +3; Edit: +1 -1.
        #expect(recap.added == 3 + 1 + 3 + 1)
        #expect(recap.removed == 2 + 2 + 1)
        #expect(recap.files == 3)
    }

    @Test func codexPatchesCountLinesAddedAndRemoved() {
        let home = RecapHome()
        let patch = "*** Begin Patch\n*** Update File: src/a.swift\n@@ func f()\n context\n-old\n+new\n+newer\n*** Add File: src/b.swift\n+line one\n+line two\n*** Delete File: src/c.swift\n*** End Patch"
        let shell = home.json(["command": ["apply_patch", "*** Begin Patch\n*** Update File: /abs/d.swift\n@@\n-x\n+y\n*** End Patch"]])
        home.codex("c", [home.codexMeta("c", cwd: "/Users/me/work/Server", at: home.stamp(3, 10)),
                         home.codexLine("response_item", at: home.stamp(3, 10, 1), payload: ["type": "custom_tool_call", "name": "apply_patch", "call_id": "p1", "input": patch]),
                         // The same call again, as a forked session's log repeats it.
                         home.codexLine("response_item", at: home.stamp(3, 10, 2), payload: ["type": "custom_tool_call", "name": "apply_patch", "call_id": "p1", "input": patch]),
                         home.codexLine("response_item", at: home.stamp(3, 10, 3), payload: ["type": "function_call", "name": "shell", "call_id": "p2", "arguments": shell]),
                         home.codexLine("response_item", at: home.stamp(3, 10, 4), payload: ["type": "function_call", "name": "shell", "call_id": "p3", "arguments": home.json(["command": ["ls"]])]),
                         home.codexLine("response_item", at: home.stamp(3, 10, 5), payload: ["type": "custom_tool_call", "name": "other", "call_id": "p4", "input": "+nope"])])
        let recap = home.read()
        #expect(recap.added == 2 + 2 + 1)
        #expect(recap.removed == 1 + 1)
        // src/c.swift is deleted without lines; four files are named, one by an absolute path.
        #expect(recap.files == 4)
    }

    @Test func filesAreDistinctPathsAcrossToolsAndEdits() {
        let home = RecapHome()
        home.claude("a", [home.claudeLine("assistant", session: "a", at: home.stamp(1, 9), content: home.toolUse("Write", id: "t1", input: ["file_path": "/Users/me/work/Server/src/a.swift", "content": "x"]))])
        home.codex("c", [home.codexMeta("c", cwd: "/Users/me/work/Server", at: home.stamp(1, 10)),
                         home.codexLine("response_item", at: home.stamp(1, 10, 1), payload: ["type": "custom_tool_call", "name": "apply_patch", "call_id": "p1",
                                                                                              "input": "*** Begin Patch\n*** Update File: src/a.swift\n@@\n-a\n+b\n*** End Patch"])])
        #expect(home.read().files == 1)
    }

    @Test func projectsAreTheLastComponentOfTheFolder() throws {
        let home = RecapHome()
        home.claude("a", [home.claudeLine(session: "a", cwd: "/Users/me/work/Nunsseop", at: home.stamp(1, 9)), home.claudeLine(session: "a", cwd: "/Users/me/work/Nunsseop", at: home.stamp(1, 9, 4))])
        home.codex("c", [home.codexMeta("c", cwd: "/Users/me/work/Server", at: home.stamp(1, 12)), home.codexLine(at: home.stamp(1, 12, 1))])
        home.claude("b", folder: "-Users-me-other", [home.claudeLine(session: "b", cwd: "/Users/me/other/Nunsseop", at: home.stamp(2, 12)), home.claudeLine(session: "b", cwd: "/Users/me/other/Nunsseop", at: home.stamp(2, 12, 2))])
        let recap = home.read()
        #expect(recap.projects == ["Nunsseop": minutes(6), "Server": minutes(1)])
        let top = try #require(recap.topProject)
        #expect(top.name == "Nunsseop")
        #expect(abs(top.share - 6.0 / 7.0) < 0.0001)
    }

    @Test func theBusiestDayAndTheLongestSessionAreTheOnesWithTheMostWork() throws {
        let home = RecapHome()
        home.claude("short", [home.claudeLine(session: "short", at: home.stamp(0, 9)), home.claudeLine(session: "short", at: home.stamp(0, 9, 4))])
        // Wednesday evening, with a name.
        home.claude("long", [home.claudeLine(session: "long", at: home.stamp(2, 19, 30)), home.claudeLine("assistant", session: "long", at: home.stamp(2, 19, 34)),
                             home.claudeLine(session: "long", at: home.stamp(2, 19, 39)),
                             home.json(["type": "custom-title", "customTitle": "Login refactor", "sessionId": "long"])])
        home.codex("c", [home.codexMeta("c", at: home.stamp(4, 22)), home.codexLine(at: home.stamp(4, 22, 3))])
        let recap = home.read()
        #expect(recap.busiestDay == 2)
        #expect(recap.days == [minutes(4), 0, minutes(9), 0, minutes(3), 0, 0])
        let longest = try #require(recap.longest)
        #expect(longest.duration == minutes(9) && longest.title == "Login refactor")
        #expect(longest.start == home.calendar.date(bySettingHour: 19, minute: 30, second: 0, of: home.calendar.date(byAdding: .day, value: 2, to: home.monday)!))
    }

    @Test func aSessionWithoutANameIsTitledByItsFolder() throws {
        let home = RecapHome()
        home.codex("c", [home.codexMeta("c", cwd: "/Users/me/work/Server", at: home.stamp(4, 22)), home.codexLine(at: home.stamp(4, 22, 3))])
        #expect(try #require(home.read().longest).title == "Server")
        home.write([home.json(["id": "c", "thread_name": "Fix the queue"])], to: ".codex/session_index.jsonl")
        #expect(try #require(home.read().longest).title == "Fix the queue")
    }

    @Test func aTieForBusiestDayGoesToTheEarlierOne() {
        let home = RecapHome()
        home.claude("a", [home.claudeLine(session: "a", at: home.stamp(1, 9)), home.claudeLine(session: "a", at: home.stamp(1, 9, 2)),
                          home.claudeLine(session: "a", at: home.stamp(3, 9)), home.claudeLine(session: "a", at: home.stamp(3, 9, 2))])
        #expect(home.read().busiestDay == 1)
    }

    @Test func aMissingHomeIsAnEmptyWeek() {
        let home = RecapHome()
        #expect(home.read().isEmpty)
        #expect(WeekRecap.read(home: home.url.appendingPathComponent("nothing"), now: home.now, calendar: home.calendar).isEmpty)
    }

    // MARK: Weeks

    @Test func theWeekStartsOnMondayWhateverTheCalendarSays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.firstWeekday = 1
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19))!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 59))!
        #expect(WeekRecap.weekStart(of: monday, calendar: calendar) == monday)
        #expect(WeekRecap.weekStart(of: monday.addingTimeInterval(3 * 86_400), calendar: calendar) == monday)
        #expect(WeekRecap.weekStart(of: sunday, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        #expect(WeekRecap.lastWeek(before: monday, calendar: calendar) == DateInterval(start: calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!, end: monday))
    }

    @Test func aWeekAcrossTheChangeToStandardTimeStillStartsAtMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Clocks went back on 1 November 2026.
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let week = WeekRecap.lastWeek(before: now, calendar: calendar)
        #expect(week.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 26)))
        #expect(week.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        #expect(week.duration == 7 * 86_400 + 3_600)
    }

    // MARK: Lines

    @Test func lineChangesCompareLinesAsAMultiset() {
        #expect(WeekRecap.lineChanges(old: "", new: "") == (0, 0))
        #expect(WeekRecap.lineChanges(old: "", new: "a\nb") == (2, 0))
        #expect(WeekRecap.lineChanges(old: "a\nb\n", new: "") == (0, 2))
        #expect(WeekRecap.lineChanges(old: "a\nb\nc", new: "a\nx\nc") == (1, 1))
        // A line moved is not a change; one more copy of a line is.
        #expect(WeekRecap.lineChanges(old: "a\nb", new: "b\na") == (0, 0))
        #expect(WeekRecap.lineChanges(old: "a\nb", new: "a\na\nb") == (1, 0))
        // Blank lines are lines, and a final newline is not one.
        #expect(WeekRecap.lineChanges(old: "a\n", new: "a\n\n\nb\n") == (3, 0))
    }

    @Test func patchChangesSkipHeaders() {
        let changes = WeekRecap.patchChanges("*** Begin Patch\n*** Update File: a.swift\n*** Move to: b.swift\n@@ class A\n ctx\n-- starts like a header\n---\n+++ also\n+added\n*** End of File\n*** Add File: c.txt\n+x\n*** End Patch")
        #expect(changes.added == 3 && changes.removed == 2)
        #expect(changes.paths == ["a.swift", "c.txt"])
    }

    // MARK: Words

    @Test func durationsAreInWholeMinutes() {
        #expect(RecapText.duration(minutes(0)) == "0m")
        #expect(RecapText.duration(minutes(40)) == "40m")
        #expect(RecapText.duration(minutes(60)) == "1h")
        #expect(RecapText.duration(minutes(21 * 60 + 40) + 20) == "21h 40m")
        #expect(RecapText.duration(minutes(59) + 40) == "1h")
    }

    @Test func theChangeFromTheWeekBefore() {
        var recap = WeekRecap(week: DateInterval(start: .now, duration: 7 * 86_400))
        recap.working = minutes(100)
        #expect(RecapText.change(recap) == "Nothing the week before")
        recap.workingBefore = minutes(98)
        #expect(RecapText.change(recap) == "Same as the week before")
        recap.workingBefore = minutes(40)
        #expect(RecapText.change(recap) == "↑ 1h vs the week before")
        recap.workingBefore = minutes(190)
        #expect(RecapText.change(recap) == "↓ 1h 30m vs the week before")
    }

    @Test func theCountsPerToolLeaveOutAToolWithNone() {
        var recap = WeekRecap(week: DateInterval(start: .now, duration: 7 * 86_400))
        recap.claudeSessions = 31
        recap.codexSessions = 15
        recap.claudeTokens = 12_900_000
        recap.codexTokens = 5_300_000
        #expect(RecapText.sessions(recap) == "Claude 31 · Codex 15")
        let (big, small) = (RecapText.compact(12_900_000), RecapText.compact(5_300_000))
        #expect(RecapText.tokens(recap) == "Claude \(big) · Codex \(small)")
        recap.codexSessions = 0
        recap.codexTokens = 0
        #expect(RecapText.sessions(recap) == "Claude 31")
        #expect(RecapText.tokens(recap) == "Claude \(big)")
        #expect(RecapText.lines(WeekRecap(week: recap.week, added: 4_210, removed: 1_380)) == "+\(4_210.formatted()) \u{2212}\(1_380.formatted())")
    }

    @Test func theDayIsNamedByItsHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let thursday = { (hour: Int) in calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: hour))! }
        let parts = [(4, "night"), (5, "morning"), (11, "morning"), (12, "afternoon"), (17, "afternoon"), (18, "evening"), (21, "evening"), (22, "night"), (23, "night")]
        for (hour, part) in parts {
            #expect(RecapText.dayPart(thursday(hour), calendar: calendar).hasSuffix(" \(part)"), Comment(rawValue: "\(hour)"))
        }
    }
}

// MARK: pi, omo, gjc, omp and OpenCode

private extension RecapHome {
    func piHeader(_ id: String, cwd: String = "/Users/me/work/Shop", title: String? = nil) -> String {
        var object: [String: Any] = ["type": "session", "version": 3, "id": id, "timestamp": stamp(-30, 9), "cwd": cwd]
        if let title { object["title"] = title }
        return json(object)
    }

    func piLine(at time: String, message: [String: Any] = ["role": "user", "content": [] as [Any]]) -> String {
        json(["type": "message", "id": UUID().uuidString, "timestamp": time, "message": message])
    }

    func piCall(_ name: String, id: String, at time: String, arguments: [String: Any]) -> String {
        piLine(at: time, message: ["role": "assistant", "content": [["type": "toolCall", "id": id, "name": name, "arguments": arguments]]])
    }

    func piResult(_ name: String, id: String, at time: String, details: [String: Any], isError: Bool = false) -> String {
        piLine(at: time, message: ["role": "toolResult", "toolCallId": id, "toolName": name, "details": details, "isError": isError, "content": [] as [Any]])
    }

    func piAnswer(at time: String, provider: String, response: String, output: Int) -> String {
        piLine(at: time, message: ["role": "assistant", "provider": provider, "model": "m", "responseId": response, "content": [] as [Any],
                                   "usage": ["input": 0, "output": output, "cacheRead": 5_000, "cacheWrite": 0]])
    }

    @discardableResult
    func pi(_ tool: AgentKind, _ id: String, folder: String = "--Users-me-work-Shop--", _ lines: [String]) -> URL {
        write(lines, to: ".\(tool.rawValue)/agent/sessions/\(folder)/2026-10-13T00-00-00-000Z_\(id).jsonl")
    }

    func millis(_ time: String) -> Int64 {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Int64(iso.date(from: time)!.timeIntervalSince1970 * 1000)
    }

    /// OpenCode's database, with the `part` table its tools write.
    func openCode(sessions: [OpenCodeFixture.Session], messages: [(session: String, at: String, data: [String: Any])],
                  parts: [(session: String, at: String, data: [String: Any])]) throws {
        try OpenCodeFixture.create(home: url, sessions: sessions)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(OpenCodeDB.url(home: url).path, &db) == SQLITE_OK else { throw POSIXError(.EIO) }
        var sql = "CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);"
        for (n, message) in messages.enumerated() {
            sql += "INSERT INTO message VALUES ('msg\(n)', '\(message.session)', \(millis(message.at)), 0, '\(json(message.data))');"
        }
        for (n, part) in parts.enumerated() {
            sql += "INSERT INTO part VALUES ('prt\(n)', 'msg0', '\(part.session)', \(millis(part.at)), 0, '\(json(part.data))');"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
    }
}

struct WeeklyRecapOtherAgentsTests {
    @Test func piStyleSessionsAreCountedPerToolWithTheirWorkingTime() {
        let home = RecapHome()
        home.pi(.omo, "o1", [home.piHeader("o1"), home.piLine(at: home.stamp(1, 9)), home.piLine(at: home.stamp(1, 9, 4))])
        home.pi(.omo, "o2", [home.piHeader("o2"), home.piLine(at: home.stamp(2, 9))])
        home.pi(.gjc, "g1", [home.piHeader("g1"), home.piLine(at: home.stamp(3, 9))])
        // Only the week before: it counts toward the change, not as a session.
        home.pi(.omp, "p1", [home.piHeader("p1"), home.piLine(at: home.stamp(-2, 9)), home.piLine(at: home.stamp(-2, 9, 2))])
        // omo's memory runs are kept apart from its sessions and are not conversations.
        home.write([home.piHeader("mem"), home.piLine(at: home.stamp(1, 12)), home.piLine(at: home.stamp(1, 12, 3))],
                   to: ".omo/memory/agents/dev/runtime/transcripts/x/transcript.jsonl")
        let recap = home.read()
        #expect(recap.otherSessions == [.omo: 2, .gjc: 1])
        #expect(recap.sessions == 3 && recap.claudeSessions == 0)
        #expect(recap.working == minutes(4) && recap.workingBefore == minutes(2))
        #expect(recap.topProject?.name == "Shop")
        #expect(RecapText.sessions(recap) == "omo 2 · gjc 1")
    }

    @Test func toolsAreListedMostSessionsFirst() {
        var recap = WeekRecap(week: DateInterval(start: .distantPast, duration: 1))
        recap.claudeSessions = 3
        recap.otherSessions = [.gjc: 1, .omo: 4, .opencode: 1]
        #expect(RecapText.sessions(recap) == "omo 4 · Claude 3 · gjc 1 · OpenCode 1")
        // Shorter, for a tile too narrow: the fewest fold into "Others", never just one of them.
        #expect(RecapText.sessionLines(recap) == ["omo 4 · Claude 3 · gjc 1 · OpenCode 1", "omo 4 · Claude 3 · Others 2", "omo 4 · Others 5"])
    }

    @Test func piEditsCountTheDiffOfTheirResultAndWritesTheirContent() {
        let home = RecapHome()
        home.pi(.omo, "o1", [
            home.piHeader("o1"),
            home.piCall("edit", id: "e1", at: home.stamp(1, 9), arguments: ["path": "Sources/A.swift", "edits": [] as [Any]]),
            home.piResult("edit", id: "e1", at: home.stamp(1, 9, 1), details: ["diff": "@@ -1,3 +1,4 @@\n 1|keep\n-2|old\n+2|new\n+3|more\n 4|end"]),
            // One call over two files.
            home.piCall("edit", id: "e2", at: home.stamp(1, 9, 2), arguments: ["input": "§multi"]),
            home.piResult("edit", id: "e2", at: home.stamp(1, 9, 3), details: ["perFileResults": [["path": "/abs/B.swift", "diff": "+1|b"],
                                                                                                  ["path": "C.swift", "diff": "-7|c\n-8|d"]]]),
            home.piCall("write", id: "w1", at: home.stamp(1, 9, 4), arguments: ["path": "D.md", "content": "one\ntwo\n"]),
            // A patch whose result names no file: the call's patch does.
            home.piCall("apply_patch", id: "p1", at: home.stamp(1, 9, 5), arguments: ["input": "*** Begin Patch\n*** Update File: E.swift\n+x\n*** End Patch"]),
            home.piResult("apply_patch", id: "p1", at: home.stamp(1, 9, 6), details: ["diff": "+1|x"]),
            // A failed edit, a result logged twice, and an edit the week before.
            home.piResult("edit", id: "e3", at: home.stamp(1, 9, 7), details: ["diff": "+1|nope"], isError: true),
            home.piResult("edit", id: "e1", at: home.stamp(1, 9, 8), details: ["diff": "+2|again"]),
            home.piResult("edit", id: "e0", at: home.stamp(-1, 9), details: ["path": "F.swift", "diff": "+1|old week"]),
        ])
        let recap = home.read()
        #expect(recap.added == 2 + 1 + 2 + 1)
        #expect(recap.removed == 1 + 2)
        #expect(recap.files == 5)
    }

    @Test func numberedDiffLinesAreCountedByTheirSign() {
        #expect(WeekRecap.numberedDiffChanges("@@ -1 +1 @@\n 1|a\n-2|b\n+2|c\n+3|-d\n--- x\n+++ y") == (added: 2, removed: 1))
        #expect(WeekRecap.numberedDiffChanges("") == (added: 0, removed: 0))
    }

    @Test func piTokensCountTowardTheSubscriptionTheirProviderBelongsTo() {
        let home = RecapHome()
        home.pi(.omo, "o1", [home.piHeader("o1"),
                             home.piAnswer(at: home.stamp(1, 9), provider: "anthropic", response: "r1", output: 40),
                             home.piAnswer(at: home.stamp(1, 9, 1), provider: "openai-codex", response: "r2", output: 30),
                             // Another seller of the same models, and the same response logged again.
                             home.piAnswer(at: home.stamp(1, 9, 2), provider: "openrouter", response: "r3", output: 1_000),
                             home.piAnswer(at: home.stamp(1, 9, 3), provider: "anthropic", response: "r1", output: 40)])
        let recap = home.read()
        #expect(recap.claudeTokens == 40 && recap.codexTokens == 30)
    }

    @Test func theWorkersOfAGjcTeamAreOneSessionInTheirRepository() {
        let home = RecapHome()
        for worker in 1...2 {
            let cwd = "/Users/me/work/Shop/.gjc/_session-lead1/state/team/1-x/worktrees/worker-\(worker)"
            home.pi(.gjc, "w\(worker)", folder: "--worker-\(worker)--", [home.piHeader("w\(worker)", cwd: cwd),
                                                                           home.piLine(at: home.stamp(1, 9, worker)), home.piLine(at: home.stamp(1, 9, worker + 2))])
        }
        let recap = home.read()
        #expect(recap.otherSessions == [.gjc: 1])
        #expect(recap.topProject?.name == "Shop")
        #expect(recap.working == minutes(3))
    }

    @Test func aPiSessionsTitleNamesTheLongestSession() {
        let home = RecapHome()
        home.pi(.omp, "p1", [home.piHeader("p1", title: "Checkout flow"), home.piLine(at: home.stamp(1, 21)), home.piLine(at: home.stamp(1, 21, 5))])
        #expect(home.read().longest?.title == "Checkout flow")
    }

    @Test func openCodeSessionsCountWithTheirSubagentsTheirEditsAndTokens() throws {
        let home = RecapHome()
        let main = OpenCodeFixture.id(1), child = OpenCodeFixture.id(2), old = OpenCodeFixture.id(3)
        let updated = home.calendar.date(byAdding: .day, value: 2, to: home.monday)!
        try home.openCode(
            sessions: [.init(id: main, directory: "/Users/me/work/Api", title: "Rate limits", updated: updated),
                       .init(id: child, directory: "/Users/me/work/Api", title: "Child session - x", parent: main, updated: updated),
                       .init(id: old, directory: "/Users/me/work/Old", updated: home.calendar.date(byAdding: .day, value: -20, to: home.monday)!)],
            messages: [(main, home.stamp(1, 10), ["role": "user", "time": ["created": 0]]),
                       (main, home.stamp(1, 10, 2), ["role": "assistant", "providerID": "anthropic", "modelID": "m",
                                                     "time": ["created": Double(home.millis(home.stamp(1, 10, 2)))],
                                                     "tokens": ["input": 10, "output": 20, "reasoning": 0, "cache": ["read": 900, "write": 5]]])],
            parts: [(child, home.stamp(1, 10, 4), ["type": "tool", "tool": "apply_patch",
                                                    "state": ["status": "completed", "input": ["patchText": "*** Begin Patch\n*** Update File: src/a.ts\n-a\n+b\n+c\n*** End Patch"]]]),
                    (main, home.stamp(1, 10, 6), ["type": "tool", "tool": "edit",
                                                   "state": ["status": "completed", "input": ["filePath": "/Users/me/work/Api/b.ts", "oldString": "x", "newString": "y\nz"]]]),
                    (main, home.stamp(1, 10, 7), ["type": "tool", "tool": "write",
                                                   "state": ["status": "error", "input": ["filePath": "c.ts", "content": "failed"]]])])
        let recap = home.read()
        #expect(recap.otherSessions == [.opencode: 1])
        #expect(recap.working == minutes(7))
        #expect(recap.added == 2 + 2 && recap.removed == 1 + 1)
        #expect(recap.files == 2)
        #expect(recap.claudeTokens == 35)
        #expect(recap.longest?.title == "Rate limits")
        #expect(recap.topProject?.name == "Api")
    }

    @Test func noOpenCodeDatabaseOrNoPartTableIsNothingToCount() throws {
        let home = RecapHome()
        #expect(home.read().isEmpty)
        try OpenCodeFixture.create(home: home.url, sessions: [])
        #expect(home.read().isEmpty)
    }
}
