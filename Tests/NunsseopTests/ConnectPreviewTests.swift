import Foundation
import Testing
@testable import Nunsseop

private func lines(_ count: Int, prefix: String = "line") -> String { (1...count).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n" }

struct LineDiffTests {
    private func kinds(_ lines: [LineDiff.Line]) -> String {
        lines.map { $0.kind == .same ? " " : $0.kind == .added ? "+" : "-" }.joined()
    }

    @Test func anAddedLineIsMarkedAddedBetweenTheLinesAroundIt() {
        let diff = LineDiff.compare("a\nb\n", "a\nx\nb\n")
        #expect(diff == [.init(kind: .same, text: "a"), .init(kind: .added, text: "x"), .init(kind: .same, text: "b")])
    }

    @Test func aRemovedLineIsMarkedRemoved() {
        let diff = LineDiff.compare("a\nx\nb\n", "a\nb\n")
        #expect(diff == [.init(kind: .same, text: "a"), .init(kind: .removed, text: "x"), .init(kind: .same, text: "b")])
    }

    @Test func aChangedLineIsTheOldOneRemovedThenTheNewOneAdded() {
        let diff = LineDiff.compare("notify = [\"a\"]\nmodel = 1\n", "notify = [\"b\"]\nmodel = 1\n")
        #expect(diff == [.init(kind: .removed, text: "notify = [\"a\"]"), .init(kind: .added, text: "notify = [\"b\"]"), .init(kind: .same, text: "model = 1")])
    }

    @Test func severalChangesAcrossAFileKeepTheUnchangedLinesBetweenThem() {
        let diff = LineDiff.compare("1\n2\n3\n4\n5\n6\n", "1\nA\n3\n4\n5\nB\n6\nC\n")
        #expect(kinds(diff) == " -+   +" + " " + "+")
        #expect(diff.filter { $0.kind == .same }.map(\.text) == ["1", "3", "4", "5", "6"])
        #expect(diff.filter { $0.kind != .same }.map(\.text) == ["2", "A", "B", "C"])
    }

    @Test func linesThatDifferOnlyInTheSpaceBeforeAColonAreTheSameLine() {
        let diff = LineDiff.compare("{\n  \"a\": 1,\n  \"b\": 2\n}\n", "{\n  \"a\" : 1,\n  \"b\" : 2,\n  \"c\" : 3\n}\n")
        #expect(diff == [.init(kind: .same, text: "{"), .init(kind: .same, text: "  \"a\" : 1,"), .init(kind: .removed, text: "  \"b\": 2"),
                         .init(kind: .added, text: "  \"b\" : 2,"), .init(kind: .added, text: "  \"c\" : 3"), .init(kind: .same, text: "}")])
    }

    @Test func aFileThatIsNotThereYetIsAllAdded() {
        let diff = LineDiff.compare("", "one\ntwo\n")
        #expect(diff == [.init(kind: .added, text: "one"), .init(kind: .added, text: "two")])
    }

    @Test func equalTextsAreAllUnchanged() {
        let diff = LineDiff.compare("a\nb\n", "a\nb\n")
        #expect(diff.allSatisfy { $0.kind == .same } && diff.count == 2)
    }

    @Test func theEndingNewlineIsNotALineOfItsOwn() {
        #expect(LineDiff.lines(of: "a\nb\n") == ["a", "b"])
        #expect(LineDiff.lines(of: "a\nb") == ["a", "b"])
        #expect(LineDiff.lines(of: "") == [])
        #expect(LineDiff.lines(of: "a\n\nb\n") == ["a", "", "b"])
    }

    @Test func textsTooBigToMatchUpAreAllRemovedThenAllAdded() {
        let old = (0..<2_100).map { "old \($0)" }.joined(separator: "\n"), new = (0..<2_100).map { "new \($0)" }.joined(separator: "\n")
        let diff = LineDiff.compare(old, new)
        #expect(diff.count == 4_200)
        #expect(diff.prefix(2_100).allSatisfy { $0.kind == .removed } && diff.suffix(2_100).allSatisfy { $0.kind == .added })
    }

    @Test func aLongUnchangedRunOnEachSideOfAChangeFoldsToTwoLinesOfContext() {
        let before = lines(30, prefix: "a") + "old\n" + lines(30, prefix: "b")
        let after = lines(30, prefix: "a") + "new\n" + lines(30, prefix: "b")
        let rows = LineDiff.rows(LineDiff.compare(before, after))
        #expect(rows.count == 1 + 2 + 2 + 2 + 1)
        guard case .folded(let head) = rows[0], case .folded(let tail) = rows[rows.count - 1] else { Issue.record("not folded at both ends"); return }
        #expect(head.count == 28 && head.first?.text == "a 1" && head.last?.text == "a 28")
        #expect(tail.count == 28 && tail.first?.text == "b 3" && tail.last?.text == "b 30")
        #expect(rows[1] == .line(.init(kind: .same, text: "a 29")) && rows[2] == .line(.init(kind: .same, text: "a 30")))
        #expect(rows[3] == .line(.init(kind: .removed, text: "old")) && rows[4] == .line(.init(kind: .added, text: "new")))
    }

    @Test func aRunBetweenTwoChangesFoldsOnlyWhenThatHidesEnoughLines() {
        func middle(_ count: Int) -> [LineDiff.Row] {
            let between = count == 0 ? "" : lines(count, prefix: "m")
            return LineDiff.rows(LineDiff.compare("x\n" + between + "y\n", "X\n" + between + "Y\n"))
        }
        // Two lines of context on each side show four lines; a fold of fewer than three lines would be as long as the lines.
        #expect(middle(4).allSatisfy { if case .folded = $0 { false } else { true } })
        #expect(middle(6).allSatisfy { if case .folded = $0 { false } else { true } })
        let seven = middle(7)
        #expect(seven.contains { if case .folded(let hidden) = $0 { hidden.count == 3 } else { false } })
    }

    @Test func foldedLinesPutBackGiveTheWholeFileInOrder() {
        let before = lines(40, prefix: "a") + "old\n" + lines(5, prefix: "b")
        let after = lines(40, prefix: "a") + "new\n" + lines(5, prefix: "b")
        let diff = LineDiff.compare(before, after)
        let flat = LineDiff.rows(diff).flatMap { row -> [LineDiff.Line] in
            switch row {
            case .line(let line): [line]
            case .folded(let hidden): hidden
            }
        }
        #expect(flat == diff)
    }

    @Test func aFileOfAddedLinesHasNothingToFold() {
        let rows = LineDiff.rows(LineDiff.compare("", lines(50)))
        #expect(rows.count == 50 && rows.allSatisfy { if case .line(let line) = $0 { line.kind == .added } else { false } })
    }

    @Test func aChangeNextToTheStartOrEndKeepsOnlyOneSideOfContext() {
        let rows = LineDiff.rows(LineDiff.compare("x\n" + lines(20), "y\n" + lines(20)))
        #expect(rows.count == 2 + 2 + 1)
        guard case .folded(let hidden) = rows[4] else { Issue.record("no fold at the end"); return }
        #expect(hidden.count == 18)
    }
}

/// What the sheet shows is what connecting writes: the same text, from the same code, against scratch homes.
struct ConnectPreviewTests {
    private let fileManager = FileManager.default

    private func put(_ text: String, at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// Every file and folder below `home`, with each file's bytes.
    private func snapshot(_ home: URL) -> [String: Data?] {
        var found: [String: Data?] = [:]
        let walker = fileManager.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = walker?.nextObject() as? URL {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            found[url.path] = isFolder ? .some(nil) : .some(try? Data(contentsOf: url))
        }
        return found
    }

    /// As Claude Code writes its settings: `"key": value`, two spaces of indent.
    private let userSettings = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "command": "mine.sh",
                    "type": "command"
                  }
                ]
              }
            ]
          },
          "model": "opus"
        }

        """

    @Test func theTextShownForClaudeCodeIsTheTextWrittenAndTheOldFileIsTheBackup() throws {
        try withTempHome { _ in
            let claude = NotifyIntegration.claudeCode
            try put(userSettings, at: claude.configURL)
            let changes = try claude.changes()
            let change = try #require(changes.first)
            #expect(changes.count == 1 && change.url == claude.configURL && change.existed && change.makesBackup)
            #expect(change.before == userSettings)

            try claude.installNow()

            #expect(text(claude.configURL) == change.after)
            #expect(text(claude.configURL.appendingPathExtension("nunsseop-backup")) == change.before)
            // The hook the user already had is in what is shown, unchanged.
            #expect(change.after.contains("mine.sh") && change.after.contains(#""model" : "opus""#))
        }
    }

    @Test func aMissingFileIsShownAsCreatedAndLeavesNoBackup() throws {
        try withTempHome { _ in
            let gemini = NotifyIntegration.gemini
            let change = try #require(try gemini.changes().first)
            #expect(!change.existed && change.before == nil && !change.makesBackup)
            try gemini.installNow()
            #expect(text(gemini.configURL) == change.after)
            #expect(!fileManager.fileExists(atPath: gemini.configURL.appendingPathExtension("nunsseop-backup").path))
        }
    }

    @Test func lookingAtWhatWouldChangeWritesNothing() throws {
        try withTempHome { home in
            try NotifyIntegration.$permissionPromptsOverride.withValue(true) {
                try put(userSettings, at: NotifyIntegration.claudeCode.configURL)
                try put("model = \"o3\"\n", at: NotifyIntegration.codex.configURL)
                try put("// mine\n", at: NotifyIntegration.openCode.configURL)
                let before = snapshot(home)
                for tool in NotifyIntegration.allCases { _ = try tool.changes() }
                #expect(snapshot(home) == before)
            }
        }
    }

    @Test func codexShowsBothFilesItWritesAndNotItsOwnScript() throws {
        try withTempHome { home in
            try NotifyIntegration.$permissionPromptsOverride.withValue(true) {
                let codex = NotifyIntegration.codex
                let others = #"{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"gk ai hook run --host codex","timeout":10}]}]}}"#
                try put("model = \"o3\"\nnotify = [\"my-notify\"]\n", at: codex.configURL)
                try put(others, at: codex.hooksURL)

                let changes = try codex.changes()
                #expect(changes.map(\.url) == [codex.configURL, codex.hooksURL])
                #expect(changes.allSatisfy { $0.existed && $0.makesBackup })
                #expect(changes[0].after.contains("my-notify") && changes[0].after.contains(CodexNotify.scriptURL.path))
                #expect(changes[1].after.contains("gk ai hook run --host codex"))

                try codex.installNow()

                for change in changes {
                    #expect(text(change.url) == change.after, Comment(rawValue: change.url.lastPathComponent))
                    #expect(text(change.url.appendingPathExtension("nunsseop-backup")) == change.before)
                }
                #expect(fileManager.fileExists(atPath: CodexNotify.scriptURL.path))
                #expect(!changes.contains { $0.url == CodexNotify.scriptURL })
                #expect(home.path.count > 0)
            }
        }
    }

    @Test func aToolAlreadyConnectedAndCurrentHasNothingToShow() throws {
        try withTempHome { _ in
            try NotifyIntegration.$permissionPromptsOverride.withValue(true) {
                for tool in NotifyIntegration.allCases {
                    try tool.installNow()
                    #expect(try tool.changes().isEmpty, Comment(rawValue: tool.name))
                    #expect(ConnectRequest(tool: tool, changes: try tool.changes()) == nil)
                }
            }
        }
    }

    @Test func aSettingsFileThatCantBeReadStillCantBeChanged() throws {
        try withTempHome { _ in
            try put("[1, 2]", at: NotifyIntegration.claudeCode.configURL)
            #expect(throws: NotifyIntegration.IntegrationError.self) { try NotifyIntegration.claudeCode.changes() }
        }
    }

    @Test func openCodeShowsItsPluginWholeAndKeepsAFileOfTheSameNameAsABackup() throws {
        try withTempHome { _ in
            let tool = NotifyIntegration.openCode
            let fresh = try #require(try tool.changes().first)
            #expect(fresh.after == NotifyIntegration.openCodePlugin && !fresh.existed)
            try put("// my own plugin\n", at: tool.configURL)
            let edited = try #require(try tool.changes().first)
            #expect(edited.existed && edited.makesBackup && edited.before == "// my own plugin\n")
            try tool.installNow()
            #expect(text(tool.configURL) == edited.after)
            #expect(text(tool.configURL.appendingPathExtension("nunsseop-backup")) == "// my own plugin\n")
        }
    }

    @Test(arguments: [NotifyIntegration.omp, .omo, .pi])
    func theExtensionOfThePiFamilyIsShownAsItIsWritten(tool: NotifyIntegration) throws {
        try withTempHome { _ in
            let fresh = try #require(try tool.changes().first)
            let agent = try #require(tool.piAgent)
            #expect(!fresh.existed && fresh.after == PiExtension.source(agent: agent))

            // A file that is not ours is kept as a backup.
            try put("export default () => {}\n", at: tool.configURL)
            let foreign = try #require(try tool.changes().first)
            #expect(foreign.makesBackup)
            try tool.installNow()
            #expect(text(tool.configURL) == foreign.after)
            #expect(text(tool.configURL.appendingPathExtension("nunsseop-backup")) == "export default () => {}\n")

            // An older file of ours is not backed up over the backup that is there, and the sheet does not say it is.
            try put(PiExtension.marker + "\n// older\n", at: tool.configURL)
            let older = try #require(try tool.changes().first)
            #expect(older.existed && !older.makesBackup)
            try tool.installNow()
            #expect(text(tool.configURL) == older.after)
            #expect(text(tool.configURL.appendingPathExtension("nunsseop-backup")) == "export default () => {}\n")
        }
    }

    @Test func onlyThePlainFilesOfSharedSettingsPromiseToKeepTheUsersHooks() {
        #expect(NotifyIntegration.allCases.filter(\.sharesItsFile) == [.claudeCode, .codex, .gemini])
    }

    @Test func theRequestNamesFilesWithTheHomeAsTildeAndTheBackupByItsName() throws {
        try withTempHome { _ in
            let claude = NotifyIntegration.claudeCode
            try put(userSettings, at: claude.configURL)
            let request = try #require(ConnectRequest(tool: claude, changes: try claude.changes()))
            let file = try #require(request.files.first)
            #expect(file.path == "~/.claude/settings.json" && file.backupName == "settings.json.nunsseop-backup" && !file.created)
            #expect(ConnectSheet.sentence(for: file) == "~/.claude/settings.json will change like this. The current file is kept as settings.json.nunsseop-backup.")
            #expect(file.lines.contains { $0.kind == .added && $0.text.contains("127.0.0.1") })
            // The user's own hook and setting are context, not part of the change, though Foundation spaces its colons differently.
            #expect(file.lines.contains { $0.kind == .same && $0.text.contains("mine.sh") })
            #expect(file.lines.contains { $0.kind == .same && $0.text.contains(#""model""#) })
            #expect(file.lines.filter { $0.kind == .removed }.count <= 2)

            let gemini = NotifyIntegration.gemini
            let created = try #require(ConnectRequest(tool: gemini, changes: try gemini.changes())?.files.first)
            #expect(created.created && created.backupName == nil)
            #expect(ConnectSheet.sentence(for: created) == "~/.gemini/settings.json will be created.")
            #expect(created.lines.allSatisfy { $0.kind == .added })
        }
    }

    @Test func theSheetsSentencesAreTranslatedIntoEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let keys = [("Connect %@?", "%@"), ("%@ will change like this.", "%@"), ("%@ will be created.", "%@"), ("The current file is kept as %@.", "%@"),
                    ("… %lld more lines", "%lld"),
                    ("Hooks you already had stay as they are. Disconnecting takes out only Nunsseop's lines.", "")]
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for (key, placeholder) in keys {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language): \(key)"))
                #expect(text.components(separatedBy: placeholder.isEmpty ? "%" : placeholder).count - 1 == (placeholder.isEmpty ? 0 : 1), Comment(rawValue: "\(language): \(key)"))
            }
        }
        let ko = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("ko.lproj/Localizable.strings").path))
        #expect(ko["Connect %@?"] as? String == "%@를 연결할까요?")
        #expect(ko["Cancel"] as? String == "취소" && ko["Connect"] as? String == "연결")
    }
}
