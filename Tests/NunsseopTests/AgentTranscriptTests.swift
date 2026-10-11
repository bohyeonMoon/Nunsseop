import Foundation
import Testing
@testable import Nunsseop

/// Fixture transcripts shaped like the tools' own session files, with made-up content.
private enum Fixture {
    static func claudeAssistant(model: String, input: Int, cacheRead: Int, cacheCreation: Int, cwd: String? = nil,
                                sidechain: Bool = false) -> String {
        let folder = cwd.map { "\"cwd\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\(folder)\"isSidechain\":\(sidechain),\"message\":{\"model\":\"\(model)\",\"role\":\"assistant\","
            + "\"usage\":{\"input_tokens\":\(input),\"cache_read_input_tokens\":\(cacheRead),"
            + "\"cache_creation_input_tokens\":\(cacheCreation),\"output_tokens\":9}}}"
    }

    static func claudeUser(cwd: String) -> String { "{\"type\":\"user\",\"cwd\":\"\(cwd)\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}" }

    static func claudePrompt(mode: String) -> String {
        "{\"type\":\"user\",\"permissionMode\":\"\(mode)\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    }

    static func claudeModeChange(_ mode: String) -> String { "{\"type\":\"permission-mode\",\"permissionMode\":\"\(mode)\",\"sessionId\":\"s\"}" }

    static let snapshot = "{\"type\":\"file-history-snapshot\",\"snapshot\":{}}"

    static func codexMeta(cwd: String, id: String) -> String {
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\",\"base_instructions\":\"x\"}}"
    }

    static func codexTurn(model: String, cwd: String) -> String {
        "{\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\",\"cwd\":\"\(cwd)\"}}"
    }

    static func codexPolicy(sandbox: String, collaboration: String = "default", approval: String = "on-request") -> String {
        "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6\",\"approval_policy\":\"\(approval)\","
            + "\"sandbox_policy\":{\"type\":\"\(sandbox)\"},\"collaboration_mode\":{\"mode\":\"\(collaboration)\",\"settings\":{}}}}"
    }

    static func codexTokens(input: Int?) -> String {
        guard let input else { return "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null}}" }
        return "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(input),"
            + "\"cached_input_tokens\":10,\"total_tokens\":\(input + 5)},\"total_token_usage\":{\"input_tokens\":999999},"
            + "\"model_context_window\":258400}}}"
    }

    static func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    @discardableResult
    static func write(_ lines: [String], to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(lines).write(to: url)
        return url
    }
}

struct AgentTranscriptParseTests {
    @Test func claudeTakesTheFirstFolderAndTheModelAndContextOfTheLastMainMessage() {
        let tail = Fixture.data([
            Fixture.snapshot,
            Fixture.claudeUser(cwd: "/Users/me/old"),
            Fixture.claudeAssistant(model: "claude-opus-5-5", input: 1, cacheRead: 2, cacheCreation: 3),
            Fixture.claudeUser(cwd: "/Users/me/proj"),
            Fixture.claudeAssistant(model: "claude-opus-5-5", input: 10, cacheRead: 80_000, cacheCreation: 4_000, cwd: "/Users/me/proj"),
            // A subagent's message and a synthetic one don't describe the session.
            Fixture.claudeAssistant(model: "claude-haiku-5-5", input: 5, cacheRead: 5, cacheCreation: 5, cwd: "/Users/me/sub", sidechain: true),
            Fixture.claudeAssistant(model: "<synthetic>", input: 0, cacheRead: 0, cacheCreation: 0),
        ])
        #expect(AgentTranscript.parse(.claude, tail: tail)
                == AgentTranscript(cwd: "/Users/me/old", model: "claude-opus-5-5", tokens: 84_010))
    }

    @Test func claudeSkipsALastLineThatIsStillBeingWritten() {
        var tail = Fixture.data([Fixture.claudeAssistant(model: "claude-sonnet-5-5", input: 7, cacheRead: 0, cacheCreation: 0, cwd: "/p")])
        tail.append(Data("{\"type\":\"assistant\",\"message\":{\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tok".utf8))
        #expect(AgentTranscript.parse(.claude, tail: tail) == AgentTranscript(cwd: "/p", model: "claude-sonnet-5-5", tokens: 7))
    }

    @Test func aTailThatStartsInTheMiddleOfALineStillParsesTheRest() {
        var tail = Data("ssage\":{\"model\":\"cut\"}}\n".utf8)
        tail.append(Fixture.data([Fixture.claudeAssistant(model: "claude-opus-5-5", input: 3, cacheRead: 0, cacheCreation: 0)]))
        #expect(AgentTranscript.parse(.claude, tail: tail).model == "claude-opus-5-5")
    }

    @Test func claudeAssistantWithoutUsageKeepsTheEarlierContext() {
        let tail = Fixture.data([
            Fixture.claudeAssistant(model: "claude-opus-5-5", input: 2, cacheRead: 40, cacheCreation: 0),
            "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-sonnet-5-5\",\"role\":\"assistant\"}}",
        ])
        #expect(AgentTranscript.parse(.claude, tail: tail) == AgentTranscript(cwd: nil, model: "claude-sonnet-5-5", tokens: 42))
    }

    @Test func codexTakesTheFirstFolderAndTheModelAndInputTokensOfTheLastCount() {
        let tail = Fixture.data([
            Fixture.codexMeta(cwd: "/Users/me/start", id: "s"),
            Fixture.codexTurn(model: "gpt-5.6", cwd: "/Users/me/proj"),
            Fixture.codexTokens(input: 12_000),
            // The first count of a session has no usage yet.
            Fixture.codexTokens(input: nil),
            Fixture.codexTokens(input: 19_492),
        ])
        #expect(AgentTranscript.parse(.codex, tail: tail) == AgentTranscript(cwd: "/Users/me/start", model: "gpt-5.6", tokens: 19_492, mode: .standard))
    }

    @Test func codexSkipsAMalformedLastLine() {
        var tail = Fixture.data([Fixture.codexTurn(model: "gpt-5.6", cwd: "/p"), Fixture.codexTokens(input: 100)])
        tail.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_to".utf8))
        #expect(AgentTranscript.parse(.codex, tail: tail) == AgentTranscript(cwd: "/p", model: "gpt-5.6", tokens: 100, mode: .standard))
    }

    @Test func theHeadOnlyAddsWhatTheTailDoesNotHave() {
        let head = Fixture.data([Fixture.codexMeta(cwd: "/Users/me/start", id: "s")])
        let tail = Fixture.data([Fixture.codexTokens(input: 5)])
        #expect(AgentTranscript.parse(.codex, head: head, tail: tail) == AgentTranscript(cwd: "/Users/me/start", model: nil, tokens: 5))
    }

    @Test func claudeTakesThePermissionModeOfTheLatestPromptOrModeChange() {
        let parse = { (lines: [String]) in AgentTranscript.parse(.claude, tail: Fixture.data(lines)).mode }
        #expect(parse([Fixture.claudePrompt(mode: "plan"), Fixture.claudePrompt(mode: "acceptEdits")]) == .acceptEdits)
        // Shift+Tab writes a line of its own between prompts.
        #expect(parse([Fixture.claudePrompt(mode: "default"), Fixture.claudeModeChange("plan")]) == .plan)
        #expect(parse([Fixture.claudePrompt(mode: "plan"), Fixture.claudePrompt(mode: "default")]) == .standard)
        #expect(parse([Fixture.claudePrompt(mode: "bypassPermissions")]) == .bypass)
        #expect(parse([Fixture.claudePrompt(mode: "auto")]) == .auto)
        #expect(parse([Fixture.claudePrompt(mode: "dontAsk")]) == .dontAsk)
        // A mode the app doesn't know is shown as the default rather than as something it isn't.
        #expect(parse([Fixture.claudePrompt(mode: "plan"), Fixture.claudePrompt(mode: "somethingNew")]) == .standard)
    }

    @Test func claudeWithoutAModeHasNone() {
        let tail = Fixture.data([Fixture.claudeUser(cwd: "/p"), Fixture.claudeAssistant(model: "claude-opus-5-5", input: 1, cacheRead: 0, cacheCreation: 0)])
        #expect(AgentTranscript.parse(.claude, tail: tail).mode == nil)
    }

    @Test func aSubagentsPermissionModeIsNotTheSessions() {
        let tail = Fixture.data([Fixture.claudePrompt(mode: "plan"),
                                 "{\"type\":\"user\",\"isSidechain\":true,\"permissionMode\":\"bypassPermissions\"}"])
        #expect(AgentTranscript.parse(.claude, tail: tail).mode == .plan)
    }

    @Test func codexIsInFullAccessOnlyWhenItsSandboxIsDangerFullAccess() {
        let parse = { (lines: [String]) in AgentTranscript.parse(.codex, tail: Fixture.data(lines)).mode }
        #expect(parse([Fixture.codexPolicy(sandbox: "danger-full-access", approval: "never")]) == .fullAccess)
        #expect(parse([Fixture.codexPolicy(sandbox: "workspace-write")]) == .standard)
        #expect(parse([Fixture.codexPolicy(sandbox: "read-only", approval: "never")]) == .standard)
        // The latest turn wins, in both directions.
        #expect(parse([Fixture.codexPolicy(sandbox: "workspace-write"), Fixture.codexPolicy(sandbox: "danger-full-access")]) == .fullAccess)
        #expect(parse([Fixture.codexPolicy(sandbox: "danger-full-access"), Fixture.codexPolicy(sandbox: "workspace-write")]) == .standard)
    }

    @Test func codexInPlanCollaborationModeIsPlan() {
        let tail = Fixture.data([Fixture.codexPolicy(sandbox: "workspace-write", collaboration: "plan")])
        #expect(AgentTranscript.parse(.codex, tail: tail).mode == .plan)
    }

    @Test func codexWithoutATurnHasNoMode() {
        let tail = Fixture.data([Fixture.codexMeta(cwd: "/p", id: "s"), Fixture.codexTokens(input: 5)])
        #expect(AgentTranscript.parse(.codex, tail: tail).mode == nil)
    }

    @Test func modelsAreShownByTheirFamilyAndVersion() {
        #expect(AgentTranscript.modelLabel("claude-opus-5-5") == "Opus 5.5")
        #expect(AgentTranscript.modelLabel("claude-sonnet-5-5") == "Sonnet 5.5")
        #expect(AgentTranscript.modelLabel("claude-opus-4-1-20250805") == "Opus 4.1")
        #expect(AgentTranscript.modelLabel("claude-sonnet-4-20250514") == "Sonnet 4")
        #expect(AgentTranscript.modelLabel("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(AgentTranscript.modelLabel("claude-opus-5-5[1m]") == "Opus 5.5")
        #expect(AgentTranscript.modelLabel("gpt-5.6") == "gpt-5.6")
        #expect(AgentTranscript.modelLabel("claude-20250101") == "claude-20250101")
    }

    @Test func contextIsShownInThousands() {
        #expect(AgentTranscript.tokensLabel(0) == "0")
        #expect(AgentTranscript.tokensLabel(842) == "842")
        #expect(AgentTranscript.tokensLabel(1_000) == "1k")
        #expect(AgentTranscript.tokensLabel(84_010) == "84k")
        #expect(AgentTranscript.tokensLabel(142_900) == "143k")
        #expect(AgentTranscript.tokensLabel(1_200_000) == "1.2M")
    }
}

struct AgentTranscriptReadTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-transcript-\(UUID().uuidString.prefix(8)).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    @Test func aMissingFileReadsAsNothing() throws {
        #expect(AgentTranscript.read(try scratch(), kind: .claude) == nil)
    }

    @Test func anEmptyFileSaysNothing() throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        #expect(AgentTranscript.read(url, kind: .claude) == AgentTranscript())
    }

    @Test func theFolderIsTheOneTheSessionStartedInEvenAfterTheShellMoved() throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = (0..<4_000).map { _ in "{\"type\":\"attachment\",\"text\":\"\(String(repeating: "x", count: 100))\"}" }
        try Fixture.write([Fixture.claudeUser(cwd: "/Users/me/proj")] + filler
                          + [Fixture.claudeAssistant(model: "claude-opus-5-5", input: 4, cacheRead: 0, cacheCreation: 0, cwd: "/Users/me/proj/worktree")], to: url)
        #expect(AgentTranscript.read(url, kind: .claude)?.cwd == "/Users/me/proj")
    }

    @Test func aLongFileIsReadFromItsEndAndItsStart() throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        // The folder is only in the first line; filler lines push it out of the tail.
        let filler = (0..<4_000).map { _ in "{\"type\":\"attachment\",\"text\":\"\(String(repeating: "x", count: 100))\"}" }
        try Fixture.write([Fixture.claudeUser(cwd: "/Users/me/first")] + filler
                          + [Fixture.claudeAssistant(model: "claude-opus-5-5", input: 4, cacheRead: 90_000, cacheCreation: 0)], to: url)
        #expect(try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) > AgentTranscript.firstWindow)
        #expect(AgentTranscript.read(url, kind: .claude)
                == AgentTranscript(cwd: "/Users/me/first", model: "claude-opus-5-5", tokens: 90_004))
    }

    @Test func aPermissionModeBeyondTheFirstWindowIsStillFound() throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        // A long turn after the prompt that set the mode: only that prompt line carries it.
        let filler = (0..<4_000).map { _ in "{\"type\":\"attachment\",\"text\":\"\(String(repeating: "x", count: 100))\"}" }
        try Fixture.write([Fixture.claudePrompt(mode: "bypassPermissions")] + filler
                          + [Fixture.claudeAssistant(model: "claude-opus-5-5", input: 4, cacheRead: 0, cacheCreation: 0)], to: url)
        #expect(try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) > 2 * AgentTranscript.firstWindow)
        #expect(AgentTranscript.read(url, kind: .claude)?.mode == .bypass)
    }

    @Test func aHugeLastLineWidensTheWindow() throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let huge = "{\"type\":\"user\",\"message\":{\"content\":\"\(String(repeating: "y", count: 600_000))\"}}"
        try Fixture.write([Fixture.claudeAssistant(model: "claude-sonnet-5-5", input: 8, cacheRead: 0, cacheCreation: 0, cwd: "/p"), huge], to: url)
        #expect(AgentTranscript.read(url, kind: .claude) == AgentTranscript(cwd: "/p", model: "claude-sonnet-5-5", tokens: 8))
    }
}

struct AgentTranscriptLookupTests {
    @Test func claudeSessionsAreFoundInAnyProjectFolder() throws {
        try withTempHome { home in
            let projects = home.appendingPathComponent(".claude/projects")
            try Fixture.write([Fixture.snapshot], to: projects.appendingPathComponent("-Users-me-a/other.jsonl"))
            let wanted = try Fixture.write([Fixture.snapshot], to: projects.appendingPathComponent("-Users-me-b/3f2a-B_9.jsonl"))
            #expect(AgentTranscripts.locate(.init(kind: .claude, session: "3f2a-B_9"), home: home)?.standardizedFileURL == wanted.standardizedFileURL)
            #expect(AgentTranscripts.locate(.init(kind: .claude, session: "nope"), home: home) == nil)
        }
    }

    @Test func theNewestFileWinsWhenASessionIsInTwoFolders() throws {
        try withTempHome { home in
            let projects = home.appendingPathComponent(".claude/projects")
            let old = try Fixture.write([Fixture.snapshot], to: projects.appendingPathComponent("-a/s1.jsonl"))
            let new = try Fixture.write([Fixture.snapshot], to: projects.appendingPathComponent("-b/s1.jsonl"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: old.path)
            #expect(AgentTranscripts.locate(.init(kind: .claude, session: "s1"), home: home)?.standardizedFileURL == new.standardizedFileURL)
        }
    }

    @Test func codexSessionsAreFoundByTheEndOfTheirRolloutName() throws {
        try withTempHome { home in
            let sessions = home.appendingPathComponent(".codex/sessions")
            try Fixture.write([], to: sessions.appendingPathComponent("2026/09/30/rollout-2026-09-30T10-00-00-aaaa-1111.jsonl"))
            let wanted = try Fixture.write([], to: sessions.appendingPathComponent("2026/10/11/rollout-2026-10-11T17-25-28-bbbb-2222.jsonl"))
            // A session id that is only the end of another one's isn't a match.
            #expect(AgentTranscripts.locate(.init(kind: .codex, session: "2222"), home: home) == nil)
            #expect(AgentTranscripts.locate(.init(kind: .codex, session: "bbbb-2222"), home: home)?.standardizedFileURL == wanted.standardizedFileURL)
            #expect(AgentTranscripts.locate(.init(kind: .codex, session: "aaaa-1111"), home: home) != nil)
            #expect(AgentTranscripts.locate(.init(kind: .codex, session: "cccc-3333"), home: home) == nil)
        }
    }

    @Test func onlyPlainSessionIdsBecomeFileNames() {
        for ok in ["3f2a-B_9", "019e-abc", String(repeating: "a", count: 64)] { #expect(AgentTranscripts.isSafe(ok), "\(ok)") }
        for bad in ["", "../x", "a/b", "a.b", "a b", "é", String(repeating: "a", count: 65)] { #expect(!AgentTranscripts.isSafe(bad), "\(bad)") }
    }

    @Test func aRefreshReadsAFileOnlyWhenItChanged() throws {
        try withTempHome { home in
            let file = home.appendingPathComponent(".claude/projects/-p/s1.jsonl")
            // Whole seconds, so setting a time again gives exactly the same one.
            let stamp = Date(timeIntervalSinceReferenceDate: 700_000_000)
            try Fixture.write([Fixture.claudeAssistant(model: "claude-opus-5-5", input: 1_000, cacheRead: 0, cacheCreation: 0, cwd: "/Users/me/p")], to: file)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
            let key = AgentTranscripts.Key(kind: .claude, session: "s1")
            var transcripts = AgentTranscripts()
            transcripts.refresh([key], home: home)
            #expect(transcripts.transcript(key) == AgentTranscript(cwd: "/Users/me/p", model: "claude-opus-5-5", tokens: 1_000))

            // Same size and time: not read again, even if the content differs.
            let same = Fixture.claudeAssistant(model: "claude-opus-5-5", input: 2_000, cacheRead: 0, cacheCreation: 0, cwd: "/Users/me/p")
            #expect(same.utf8.count == (try Data(contentsOf: file)).count - 1)
            try Fixture.write([same], to: file)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
            transcripts.refresh([key], home: home)
            #expect(transcripts.transcript(key)?.tokens == 1_000)

            // Grown within the same second: read again.
            try Fixture.write([same, Fixture.claudeAssistant(model: "claude-opus-5-5", input: 3_000, cacheRead: 0, cacheCreation: 0)], to: file)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
            transcripts.refresh([key], home: home)
            #expect(transcripts.transcript(key)?.tokens == 3_000)
        }
    }

    @Test func aMissingFileIsLookedForAgainOnlyAfterAWhile() throws {
        try withTempHome { home in
            let key = AgentTranscripts.Key(kind: .codex, session: "abc-1")
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            var transcripts = AgentTranscripts()
            transcripts.refresh([key], home: home, now: start)
            #expect(transcripts.transcript(key) == nil)

            try Fixture.write([Fixture.codexTurn(model: "gpt-5.6", cwd: "/p"), Fixture.codexTokens(input: 50)],
                              to: home.appendingPathComponent(".codex/sessions/2026/10/11/rollout-2026-10-11T00-00-00-abc-1.jsonl"))
            transcripts.refresh([key], home: home, now: start.addingTimeInterval(AgentTranscripts.retryInterval - 1))
            #expect(transcripts.transcript(key) == nil)
            transcripts.refresh([key], home: home, now: start.addingTimeInterval(AgentTranscripts.retryInterval))
            #expect(transcripts.transcript(key) == AgentTranscript(cwd: "/p", model: "gpt-5.6", tokens: 50, mode: .standard))
        }
    }

    @Test func aFileThatGoesAwayIsLostAndOneNoLongerListedIsForgotten() throws {
        try withTempHome { home in
            let file = home.appendingPathComponent(".claude/projects/-p/s1.jsonl")
            try Fixture.write([Fixture.claudeAssistant(model: "claude-opus-5-5", input: 5, cacheRead: 0, cacheCreation: 0)], to: file)
            let key = AgentTranscripts.Key(kind: .claude, session: "s1")
            var transcripts = AgentTranscripts()
            transcripts.refresh([key], home: home)
            #expect(transcripts.transcript(key) != nil)
            try FileManager.default.removeItem(at: file)
            transcripts.refresh([key], home: home)
            #expect(transcripts.transcript(key) == nil)
            try Fixture.write([Fixture.claudeAssistant(model: "claude-opus-5-5", input: 5, cacheRead: 0, cacheCreation: 0)], to: file)
            transcripts.refresh([key], home: home, now: .now.addingTimeInterval(AgentTranscripts.retryInterval))
            #expect(transcripts.transcript(key) != nil)
            transcripts.refresh([], home: home)
            #expect(transcripts.transcript(key) == nil)
        }
    }

    @Test func anUnsafeSessionIdIsNeverLookedUp() throws {
        try withTempHome { home in
            // "../secret" from a project folder lands next to the project folders.
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/-p"), withIntermediateDirectories: true)
            try Fixture.write([Fixture.claudeUser(cwd: "/secret")], to: home.appendingPathComponent(".claude/projects/secret.jsonl"))
            let key = AgentTranscripts.Key(kind: .claude, session: "../secret")
            var transcripts = AgentTranscripts()
            transcripts.refresh([key], home: home)
            #expect(transcripts.transcript(key) == nil)
        }
    }
}
