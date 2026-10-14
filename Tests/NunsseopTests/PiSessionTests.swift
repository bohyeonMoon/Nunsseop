import Foundation
import Testing
@testable import Nunsseop

struct PiSessionFilesTests {
    @Test func theIdIsTheEndOfTheFileName() {
        let id = "01a12655-029b-786a-b1ff-45131b52e032"
        #expect(PiSessions.sessionID(fileName: "2026-10-10T15-01-07-867Z_\(id).jsonl") == id)
        #expect(PiSessions.sessionID(path: "/Users/me/.omo/agent/sessions/--x--/2026-10-10T15-01-07-867Z_\(id).jsonl") == id)
        for bad in ["\(id).jsonl", "2026-10-10T15-01-07-867Z_\(id).json", "2026-10-10T15-01-07-867Z-\(id).jsonl",
                    "2026-10-10T15-01-07-867Z_.jsonl", "2026-10-10T15-01-07-867Z_../../x.jsonl", "2026-10-10T15-01-07-867Z_a b c d e f g.jsonl",
                    "notatime_\(id).jsonl", "", "2026-10-10T15-01-07-867Z_\(id)x/.jsonl"] {
            #expect(PiSessions.sessionID(fileName: bad) == nil, "\(bad)")
        }
    }

    @Test func eachToolKeepsItsFilesInItsOwnFolder() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(PiSessions.root(.omp, home: home)?.path == "/Users/me/.omp/agent/sessions")
        #expect(PiSessions.root(.gjc, home: home)?.path == "/Users/me/.gjc/agent/sessions")
        #expect(PiSessions.root(.omo, home: home)?.path == "/Users/me/.omo/agent/sessions")
        #expect(PiSessions.root(.pi, home: home)?.path == "/Users/me/.pi/agent/sessions")
        #expect(PiSessions.root(.claude, home: home) == nil && PiSessions.root(.opencode, home: home) == nil)
    }

    @Test func theNewestFileNamedForTheSessionInAnyFolderWins() throws {
        try withTempHome { home in
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let id = PiFixture.id(1)
            let older = try PiFixture.write([PiFixture.header(id: id, cwd: "/a")], kind: .omp, home: home, id: id, ago: 900, now: now, folder: "-a")
            let newer = try PiFixture.write([PiFixture.header(id: id, cwd: "/b")], kind: .omp, home: home, id: id, ago: 100, now: now, folder: "-b")
            try PiFixture.write([PiFixture.header(id: id, cwd: "/c")], kind: .omo, home: home, id: id, now: now)
            // Compared by path: the temporary folder is reached through a symbolic link.
            let located = PiSessions.locate(.omp, session: id, home: home)
            #expect(located?.resolvingSymlinksInPath() == newer.resolvingSymlinksInPath() && older.lastPathComponent != newer.lastPathComponent)
            #expect(PiSessions.locate(.omp, session: PiFixture.id(2), home: home) == nil)
            #expect(PiSessions.locate(.pi, session: id, home: home) == nil)
            #expect(PiSessions.locate(.claude, session: id, home: home) == nil)
        }
    }
}

struct PiTranscriptTests {
    private func parse(_ kind: AgentKind, _ lines: [String]) -> AgentTranscript {
        AgentTranscript.parse(kind, tail: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    @Test func omoAndPiGiveFolderModelAndTheContextTheLastRequestUsed() {
        for kind in [AgentKind.omo, .pi] {
            let transcript = parse(kind, [
                PiFixture.header(id: PiFixture.id(1), cwd: "/Users/me/work"), PiFixture.modelChange(modelId: "claude-opus-4-8"), PiFixture.user(),
                PiFixture.assistant(model: "claude-sonnet-5-5", input: 2, output: 275, cacheRead: 38_155, cacheWrite: 4_062),
                PiFixture.assistant(model: "claude-sonnet-5-5", input: 2, output: 2_208, cacheRead: 42_217, cacheWrite: 14_786)])
            // Input, cache read and cache write of the last answer; its output is not context yet.
            #expect(transcript == AgentTranscript(cwd: "/Users/me/work", model: "claude-sonnet-5-5", tokens: 57_005), "\(kind)")
        }
    }

    @Test func ompAndGjcNameTheModelWithItsProviderAndTitleTheSession() {
        for kind in [AgentKind.omp, .gjc] {
            let transcript = parse(kind, [PiFixture.titleLine("Compare terminal multiplexers"),
                                           PiFixture.header(id: PiFixture.id(1), cwd: "/Users/me/work", title: "Compare terminal multiplexers"),
                                           PiFixture.modelChange(model: "anthropic/claude-opus-5-5")])
            #expect(transcript == AgentTranscript(cwd: "/Users/me/work", model: "claude-opus-5-5", name: "Compare terminal multiplexers"), "\(kind)")
        }
        // The first folder stays: the shell moves on, the session does not.
        let moved = parse(.omp, [PiFixture.header(id: PiFixture.id(1), cwd: "/first"), PiFixture.header(id: PiFixture.id(2), cwd: "/second")])
        #expect(moved.cwd == "/first")
    }

    /// omp rewrites its first line (`title`) as the title changes; the header keeps the one it began with.
    @Test func ompsTitleLineBeatsTheHeadersTitleWhicheverComesFirst() {
        let older = PiFixture.header(id: PiFixture.id(1), cwd: "/w", title: "Old header title")
        for lines in [[PiFixture.titleLine("Current title"), older], [older, PiFixture.titleLine("Current title")]] {
            #expect(parse(.omp, lines).name == "Current title")
        }
        // No title in the header at all, as in most real omp files.
        #expect(parse(.omp, [PiFixture.titleLine("Current title"), PiFixture.header(id: PiFixture.id(1), cwd: "/w")]).name == "Current title")
        // A later rename still wins over both (see `AgentNameScan`).
        #expect(parse(.omp, [older]).name == "Old header title")
    }

    @Test func aFailedRequestLeavesTheContextAsItWas() {
        let transcript = parse(.pi, [PiFixture.header(id: PiFixture.id(1), cwd: "/w"), PiFixture.assistant(model: "claude-sonnet-5", input: 10, cacheRead: 990),
                                     PiFixture.assistant(model: "claude-sonnet-5", input: 0, output: 0)])
        #expect(transcript.tokens == 1_000 && transcript.model == "claude-sonnet-5")
    }

    @Test func theseToolsHaveNoModeToReport() {
        let transcript = parse(.omo, [PiFixture.header(id: PiFixture.id(1), cwd: "/w"), PiFixture.assistant(model: "m", cacheRead: 5)])
        #expect(transcript.mode == nil)
        // A line that is not JSON, or has another shape, is skipped; OpenCode has no file at all.
        #expect(parse(.omo, ["{not json", "[]", "{\"type\":\"message\",\"message\":5}"]) == AgentTranscript())
        #expect(parse(.opencode, [PiFixture.header(id: PiFixture.id(1), cwd: "/w")]) == AgentTranscript())
    }

    @Test func aFileIsReadForAllOfItAndWidenedOnlyForWhatItLacks() throws {
        try withTempHome { home in
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let id = PiFixture.id(3)
            // A header, a long run of lines, then the answer: the tail window finds the model, the head the folder and the title.
            var lines = [PiFixture.header(id: id, cwd: "/Users/me/work", title: "A long session")]
            lines += (0..<3_000).map { _ in PiFixture.user(String(repeating: "x", count: 200)) }
            lines.append(PiFixture.assistant(model: "claude-sonnet-5-5", input: 1, cacheRead: 4_000, cacheWrite: 10))
            let url = try PiFixture.write(lines, kind: .omo, home: home, id: id, now: now)
            #expect((try Data(contentsOf: url)).count > AgentTranscript.firstWindow)
            #expect(AgentTranscript.read(url, kind: .omo) == AgentTranscript(cwd: "/Users/me/work", model: "claude-sonnet-5-5", tokens: 4_011, name: "A long session"))
        }
    }
}

struct PiNameTests {
    private func scanned(_ lines: [String], family: AgentNameScan.Family = .pi, chunk: Int = AgentNameScan.chunk) throws -> AgentNameScan {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-name-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        var scan = AgentNameScan(family: family)
        scan.advance(url, chunk: chunk)
        return scan
    }

    @Test func theLatestSessionInfoOrTitleChangeIsTheName() throws {
        #expect(try scanned([PiFixture.user(), PiFixture.sessionInfo("First"), PiFixture.assistant(model: "m"), PiFixture.sessionInfo("Second")]).name == "Second")
        #expect(try scanned([PiFixture.titleChange("Auto title"), PiFixture.user(), PiFixture.titleChange("Renamed\nby hand")]).name == "Renamed by hand")
        #expect(try scanned([PiFixture.user(), PiFixture.assistant(model: "m")]).name == nil)
        // An empty name keeps the one before it.
        #expect(try scanned([PiFixture.sessionInfo("Kept"), PiFixture.sessionInfo("   ")]).name == "Kept")
    }

    @Test func aMarkerInsideAMessageIsNotATitle() throws {
        let talk = PiFixture.user("the line session_info and title_change are mentioned here")
        #expect(try scanned([talk, PiFixture.sessionInfo("Real")]).name == "Real")
        #expect(try scanned([talk]).name == nil)
    }

    @Test func aSmallChunkFindsTheSameNameAndATitleSplitAcrossChunks() throws {
        let lines = [PiFixture.user(String(repeating: "y", count: 300)), PiFixture.sessionInfo("Across chunks"), PiFixture.user("z")]
        for chunk in [1, 7, 64, 4_096] { #expect(try scanned(lines, chunk: chunk).name == "Across chunks", "chunk \(chunk)") }
    }

    @Test func theClaudeScanDoesNotReadTheOtherToolsLinesNorTheOtherWayAround() throws {
        #expect(try scanned([PiFixture.sessionInfo("Pi's")], family: .claude).name == nil)
        let claude = PiFixture.line(["type": "custom-title", "customTitle": "Claude's", "sessionId": "s"])
        #expect(try scanned([claude], family: .pi).name == nil)
        #expect(try scanned([claude], family: .claude).name == "Claude's")
    }

    @Test func aScanGrowsWithTheFileAndStartsOverWhenItIsReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-name-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((PiFixture.sessionInfo("One") + "\n").utf8).write(to: url)
        var scan = AgentNameScan(family: .pi)
        scan.advance(url)
        #expect(scan.name == "One")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((PiFixture.user() + "\n" + PiFixture.sessionInfo("Two") + "\n").utf8))
        try handle.close()
        scan.advance(url)
        #expect(scan.name == "Two" && scan.family == .pi)
        try Data((PiFixture.sessionInfo("Other") + "\n").utf8).write(to: url)
        scan.advance(url)
        #expect(scan.name == "Other")
    }
}

struct PiTranscriptRefreshTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func eachToolsSessionIsFoundAndNamedFromItsOwnFiles() throws {
        try withTempHome { home in
            let cases: [(AgentKind, [String], String?)] = [
                (.omo, [PiFixture.header(id: PiFixture.id(1), cwd: "/Users/me/a"), PiFixture.user(), PiFixture.assistant(model: "claude-sonnet-5-5", input: 0, cacheRead: 100),
                        PiFixture.sessionInfo("Fix the build")], "Fix the build"),
                (.pi, [PiFixture.header(id: PiFixture.id(2), cwd: "/Users/me/b"), PiFixture.assistant(model: "claude-sonnet-5", input: 0, cacheRead: 200)], nil),
                (.omp, [PiFixture.titleLine("Header title"), PiFixture.header(id: PiFixture.id(3), cwd: "/Users/me/c", title: "Header title"),
                        PiFixture.assistant(model: "claude-opus-5-5", input: 0, cacheRead: 300), PiFixture.titleChange("Newer title")], "Newer title"),
                (.gjc, [PiFixture.header(id: PiFixture.id(4), cwd: "/Users/me/d", title: "Only the header"),
                        PiFixture.assistant(model: "claude-sonnet-5", input: 0, cacheRead: 400)], "Only the header")]
            var keys = Set<AgentTranscripts.Key>()
            for (index, entry) in cases.enumerated() {
                try PiFixture.write(entry.1, kind: entry.0, home: home, id: PiFixture.id(index + 1), now: now)
                keys.insert(AgentTranscripts.Key(kind: entry.0, session: PiFixture.id(index + 1)))
            }
            var transcripts = AgentTranscripts()
            transcripts.refresh(keys, home: home, now: now)
            for (index, entry) in cases.enumerated() {
                let found = transcripts.transcript(AgentTranscripts.Key(kind: entry.0, session: PiFixture.id(index + 1)))
                #expect(found?.name == entry.2 && found?.tokens == (index + 1) * 100 && found?.cwd == "/Users/me/\(["a", "b", "c", "d"][index])", "\(entry.0)")
            }
            // Another tool's id is not found in this tool's files.
            transcripts.refresh([AgentTranscripts.Key(kind: .omp, session: PiFixture.id(1))], home: home, now: now.addingTimeInterval(60))
            #expect(transcripts.transcript(AgentTranscripts.Key(kind: .omp, session: PiFixture.id(1))) == nil)
        }
    }

    @Test func openCodeIsReadFromItsDatabaseAndNotMoreOftenThanEveryFewSeconds() throws {
        try withTempHome { home in
            let id = OpenCodeFixture.id(7)
            try OpenCodeFixture.create(home: home, sessions: [OpenCodeFixture.Session(id: id, directory: "/Users/me/oc", title: "Fix the parser", updated: now)],
                                       answers: [OpenCodeFixture.Answer(session: id, created: now.addingTimeInterval(-60), model: "gpt-5.5", input: 100, read: 5_000, write: 20),
                                                 OpenCodeFixture.Answer(session: id, created: now, model: "gpt-5.6", input: 500, read: 80_000, write: 3)])
            let key = AgentTranscripts.Key(kind: .opencode, session: id)
            var transcripts = AgentTranscripts()
            transcripts.refresh([key], home: home, now: now)
            #expect(transcripts.transcript(key) == AgentTranscript(cwd: "/Users/me/oc", model: "gpt-5.6", tokens: 80_503, name: "Fix the parser"))
            // The database is left alone for a few seconds, then looked at again.
            try OpenCodeFixture.add([OpenCodeFixture.Answer(session: id, created: now.addingTimeInterval(30), model: "gpt-5.7", input: 1, read: 9, write: 0)], home: home)
            transcripts.refresh([key], home: home, now: now.addingTimeInterval(AgentTranscripts.databaseInterval - 1))
            #expect(transcripts.transcript(key)?.model == "gpt-5.6")
            transcripts.refresh([key], home: home, now: now.addingTimeInterval(AgentTranscripts.databaseInterval))
            #expect(transcripts.transcript(key)?.model == "gpt-5.7" && transcripts.transcript(key)?.tokens == 10)
            // A database that went away leaves the last answer in place.
            try FileManager.default.removeItem(at: OpenCodeDB.url(home: home))
            transcripts.refresh([key], home: home, now: now.addingTimeInterval(AgentTranscripts.databaseInterval * 3))
            #expect(transcripts.transcript(key)?.model == "gpt-5.7")
        }
    }
}
