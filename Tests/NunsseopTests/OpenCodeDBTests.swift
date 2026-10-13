import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import Nunsseop

struct OpenCodeDBTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func sessions(_ home: URL) throws {
        try OpenCodeFixture.create(home: home, sessions: [
            .init(id: OpenCodeFixture.id(1), directory: "/Users/me/a", title: "Real title", updated: now.addingTimeInterval(-60)),
            .init(id: OpenCodeFixture.id(2), directory: "/Users/me/b", updated: now.addingTimeInterval(-120)),
            .init(id: OpenCodeFixture.id(3), directory: "/Users/me/c", title: "Child session - x", parent: OpenCodeFixture.id(1), updated: now),
            .init(id: OpenCodeFixture.id(4), directory: "/Users/me/d", title: "Archived", updated: now, archived: now),
            .init(id: OpenCodeFixture.id(5), directory: "/Users/me/e", title: "Old", updated: now.addingTimeInterval(-8 * 86_400)),
            .init(id: OpenCodeFixture.id(6), directory: "/Users/me/f", title: "Newest\nwith a break", updated: now.addingTimeInterval(-30))])
    }

    @Test func recentSessionsAreTheMainOnesNotArchivedOfTheLastWeekNewestFirst() throws {
        try withTempHome { home in
            try sessions(home)
            let found = OpenCodeDB.recent(home: home, since: now.addingTimeInterval(-7 * 86_400), limit: 10)
            #expect(found.map(\.id) == [OpenCodeFixture.id(6), OpenCodeFixture.id(1), OpenCodeFixture.id(2)])
            #expect(found.map(\.directory) == ["/Users/me/f", "/Users/me/a", "/Users/me/b"])
            // A title is a name only once OpenCode has given one; a line break is a space.
            #expect(found.map(\.title) == ["Newest with a break", "Real title", nil])
            #expect(found.first?.updated == now.addingTimeInterval(-30))
            #expect(OpenCodeDB.recent(home: home, since: now.addingTimeInterval(-7 * 86_400), limit: 2).map(\.id) == [OpenCodeFixture.id(6), OpenCodeFixture.id(1)])
        }
    }

    @Test func defaultTitlesAreNoNames() {
        #expect(OpenCodeDB.title("New session - 2026-10-10T00:00:00.000Z") == nil)
        #expect(OpenCodeDB.title("Child session - 2026-10-10T00:00:00.000Z") == nil)
        #expect(OpenCodeDB.title("New session about parsers") == "New session about parsers")
        #expect(OpenCodeDB.title("") == nil)
    }

    @Test func aMissingOrForeignDatabaseHasNothing() throws {
        try withTempHome { home in
            #expect(OpenCodeDB.recent(home: home, since: .distantPast, limit: 5).isEmpty)
            #expect(OpenCodeDB.transcript(session: OpenCodeFixture.id(1), home: home) == nil)
            let file = OpenCodeDB.url(home: home)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not a database".utf8).write(to: file)
            #expect(OpenCodeDB.recent(home: home, since: .distantPast, limit: 5).isEmpty)
            #expect(OpenCodeDB.transcript(session: OpenCodeFixture.id(1), home: home) == nil)
        }
    }

    @Test func theDatabaseIsOnlyReadAndAnIdIsOnlyEverAValue() throws {
        try withTempHome { home in
            try sessions(home)
            let file = OpenCodeDB.url(home: home)
            let folder = file.deletingLastPathComponent()
            func state() throws -> (String, [String]) {
                (SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined(),
                 try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted())
            }
            let before = try state()
            _ = OpenCodeDB.recent(home: home, since: .distantPast, limit: 50)
            _ = OpenCodeDB.transcript(session: OpenCodeFixture.id(1), home: home)
            #expect(OpenCodeDB.transcript(session: "x' OR '1'='1", home: home) == nil)
            #expect(OpenCodeDB.transcript(session: "x'; DROP TABLE session; --", home: home) == nil)
            let after = try state()
            #expect(before.0 == after.0 && before.1 == after.1)
            #expect(OpenCodeDB.recent(home: home, since: .distantPast, limit: 50).count == 4)
        }
    }

    @Test func aSessionGivesItsFolderNameAndTheLatestAnswersModelAndContext() throws {
        try withTempHome { home in
            try sessions(home)
            let id = OpenCodeFixture.id(1)
            // No answer yet: the folder and the name only.
            #expect(OpenCodeDB.transcript(session: id, home: home) == AgentTranscript(cwd: "/Users/me/a", name: "Real title"))
            try OpenCodeFixture.add([.init(session: id, created: now.addingTimeInterval(-90), model: "old-model", input: 1, read: 1, write: 1),
                                     .init(session: id, created: now.addingTimeInterval(-30), model: "gpt-5.5-pro", input: 400, read: 80_000, write: 100),
                                     // Another session's, newer.
                                     .init(session: OpenCodeFixture.id(2), created: now, model: "other", input: 9, read: 9, write: 9)], home: home)
            #expect(OpenCodeDB.transcript(session: id, home: home)
                    == AgentTranscript(cwd: "/Users/me/a", model: "gpt-5.5-pro", tokens: 80_500, name: "Real title"))
            #expect(OpenCodeDB.transcript(session: OpenCodeFixture.id(2), home: home)?.name == nil)
        }
    }

    /// OpenCode writes `tokens` as zeros for a message it has only begun, and leaves them for an aborted or failed one.
    @Test func anAnswerWithoutTokensDoesNotEraseTheContextOfTheLastRealOne() throws {
        try withTempHome { home in
            try sessions(home)
            let id = OpenCodeFixture.id(1)
            try OpenCodeFixture.add([.init(session: id, created: now.addingTimeInterval(-60), model: "gpt-5.5", input: 400, read: 80_000, write: 100),
                                     .init(session: id, created: now.addingTimeInterval(-10), model: "gpt-5.6", input: 0, read: 0, write: 0)], home: home)
            // The model is the newest answer's; the context the newest that counted any.
            #expect(OpenCodeDB.transcript(session: id, home: home)
                    == AgentTranscript(cwd: "/Users/me/a", model: "gpt-5.6", tokens: 80_500, name: "Real title"))
            // Only zeros: no figure, not zero.
            let bare = OpenCodeFixture.id(2)
            try OpenCodeFixture.add([.init(session: bare, created: now, model: "gpt-5.5", input: 0, read: 0, write: 0)], home: home)
            #expect(OpenCodeDB.transcript(session: bare, home: home)?.tokens == nil)
        }
    }

    /// OpenCode's database is in WAL mode. Reading it gives what is committed, does not wait for a writer, and changes none of its data.
    @Test func aDatabaseInWalModeIsReadWhileAnotherConnectionWritesAndItsDataStaysAsItWas() throws {
        try withTempHome { home in
            let id = OpenCodeFixture.id(1)
            try OpenCodeFixture.create(home: home, sessions: [.init(id: id, directory: "/Users/me/a", title: "Real title", updated: now)],
                                       answers: [.init(session: id, created: now.addingTimeInterval(-30), model: "gpt-5.5", input: 400, read: 80_000, write: 100)], wal: true)
            let file = OpenCodeDB.url(home: home)
            let folder = file.deletingLastPathComponent()
            func digest() throws -> String { SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() }
            let before = try digest()
            _ = OpenCodeDB.transcript(session: id, home: home)
            // Reading leaves SQLite's own `-shm` and `-wal` beside the database, as the doc of `OpenCodeDB` says; nothing else.
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(Set(names).isSubset(of: ["opencode.db", "opencode.db-shm", "opencode.db-wal"]))
            #expect(try digest() == before)

            let writer = try OpenCodeFixture.holdWriteLock(home: home, session: id)
            defer { sqlite3_close(writer) }
            let started = Date()
            #expect(OpenCodeDB.transcript(session: id, home: home)
                    == AgentTranscript(cwd: "/Users/me/a", model: "gpt-5.5", tokens: 80_500, name: "Real title"))
            #expect(OpenCodeDB.recent(home: home, since: .distantPast, limit: 5).map(\.id) == [id])
            #expect(Date().timeIntervalSince(started) < 2)
        }
    }
}
