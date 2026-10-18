import Foundation
import Testing
@testable import Nunsseop

struct AgentActivityTests {
    private func lines(_ objects: [[String: Any]]) throws -> Data {
        try objects.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").data(using: .utf8)!
    }

    private func claudeTool(_ name: String, _ input: [String: Any], sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "isSidechain": sidechain,
         "message": ["model": "claude-opus-5-5", "content": [["type": "text", "text": "On it."], ["type": "tool_use", "id": "t", "name": name, "input": input]]]]
    }

    private func claudePrompt(_ text: String) -> [String: Any] { ["type": "user", "message": ["role": "user", "content": text]] }

    private func claudeResult() -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "ok"]]]]
    }

    @Test func claudeCodesLastStepAndTheTurnsEdits() throws {
        let data = try lines([
            claudePrompt("first"),
            claudeTool("Edit", ["file_path": "/p/old.swift", "old_string": "a", "new_string": "b"]),
            claudePrompt("second"),
            claudeTool("Read", ["file_path": "/p/a.swift"]),
            claudeResult(),
            claudeTool("Edit", ["file_path": "/p/a.swift", "old_string": "let x = 1\nprint(x)", "new_string": "let x = 2\nlet y = 3\nprint(x)"]),
            claudeResult(),
            claudeTool("MultiEdit", ["file_path": "/p/b.swift", "edits": [["old_string": "1", "new_string": "2"], ["old_string": "3", "new_string": ""]]]),
            claudeResult(),
            claudeTool("Bash", ["command": "swift test\n# and more"]),
            // A subagent's step is its own, not the session's.
            claudeTool("Write", ["file_path": "/p/side.swift", "content": "x"], sidechain: true),
        ])
        let transcript = AgentTranscript.parse(.claude, tail: data)
        #expect(transcript.activity == AgentActivity(verb: .run, subject: "swift test"))
        // The tool results in between don't start a turn; the second prompt does.
        #expect(transcript.edits.map(\.path) == ["/p/a.swift", "/p/b.swift", "/p/b.swift"])
        #expect(transcript.edits[0].added == 2 && transcript.edits[0].removed == 1)
        #expect(transcript.model == "claude-opus-5-5")
    }

    @Test func aNewPromptClearsTheLastStep() throws {
        let data = try lines([claudeTool("Grep", ["pattern": "TODO"]), claudePrompt("next")])
        let transcript = AgentTranscript.parse(.claude, tail: data)
        #expect(transcript.activity == nil && transcript.edits.isEmpty)
    }

    @Test func claudeToolsHaveTheirVerbs() {
        #expect(AgentActivity.claude(name: "Write", input: ["file_path": "/n.swift", "content": "a\nb"]).first?.edit?.added == 2)
        #expect(AgentActivity.claude(name: "Glob", input: ["pattern": "**/*.swift"]).first == AgentActivity(verb: .search, subject: "**/*.swift"))
        #expect(AgentActivity.claude(name: "AskUserQuestion", input: ["questions": [["question": "Which version?"]]]).first
                == AgentActivity(verb: .ask, subject: "Which version?"))
        #expect(AgentActivity.claude(name: "Task", input: ["description": "Look for callers"]).first?.verb == .delegate)
        #expect(AgentActivity.claude(name: "mcp__github__create_issue", input: [:]).first?.verb == .tool("issue"))
    }

    @Test func codexsCommandsAndPatches() throws {
        let patch = """
        *** Begin Patch
        *** Update File: src/a.ts
        @@ function f()
         keep
        -old
        +new
        +more
        *** Add File: src/b.ts
        +hello
        *** End Patch
        """
        let data = try lines([
            ["type": "event_msg", "payload": ["type": "user_message", "message": "fix it"]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "shell",
                                                   "arguments": #"{"command":["bash","-lc","npm test\nnpm run lint"]}"#]],
            ["type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch", "input": patch]],
        ])
        let transcript = AgentTranscript.parse(.codex, tail: data)
        #expect(transcript.activity == AgentActivity(verb: .write, subject: "src/b.ts", edit: AgentActivity.Edit(path: "src/b.ts", old: "", new: "hello")))
        #expect(transcript.edits.map(\.path) == ["src/a.ts", "src/b.ts"])
        #expect(transcript.edits[0].added == 2 && transcript.edits[0].removed == 1)
        #expect(AgentActivity.codex(name: "shell", arguments: #"{"command":["bash","-lc","npm test"]}"#, input: nil).first
                == AgentActivity(verb: .run, subject: "npm test"))
        #expect(AgentActivity.codex(name: "exec_command", arguments: #"{"cmd":"ls -la"}"#, input: nil).first == AgentActivity(verb: .run, subject: "ls -la"))
    }

    @Test func aTurnKeepsItsLatestEdits() throws {
        let edits = (0..<(AgentActivity.editLimit + 5)).map { claudeTool("Edit", ["file_path": "/p/\($0).swift", "old_string": "a", "new_string": "b"]) }
        let transcript = AgentTranscript.parse(.claude, tail: try lines(edits))
        #expect(transcript.edits.count == AgentActivity.editLimit)
        #expect(transcript.edits.last?.path == "/p/\(AgentActivity.editLimit + 4).swift")
    }

    @Test func theSubjectIsOneShortLine() {
        let long = String(repeating: "x", count: 500)
        #expect(AgentActivity(verb: .run, subject: "  \(long)\nsecond").subject.count == AgentActivity.subjectLimit)
    }

    @Test func aDiffKeepsWhatIsSharedAndPutsRemovedBeforeAdded() {
        let lines = DiffLine.diff("a\nb\nc\nd", "a\nB\nc\nd\ne")
        #expect(lines == [DiffLine(kind: .same, text: "a"), DiffLine(kind: .removed, text: "b"), DiffLine(kind: .added, text: "B"),
                          DiffLine(kind: .same, text: "c"), DiffLine(kind: .same, text: "d"), DiffLine(kind: .added, text: "e")])
        #expect(DiffLine.diff("", "x\ny").map(\.kind) == [.added, .added])
        #expect(DiffLine.diff("x", "").map(\.kind) == [.removed])
        #expect(DiffLine.diff("same", "same").map(\.kind) == [.same])
    }

    @Test func aHugeDiffIsTheOldLinesThenTheNew() {
        let old = (0...DiffLine.limit).map(String.init).joined(separator: "\n")
        let lines = DiffLine.diff(old, "new")
        #expect(lines.count == DiffLine.limit + 2)
        #expect(lines.last == DiffLine(kind: .added, text: "new"))
    }

    @Test func theWordsAreTranslatedIntoEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let keys = ["Read", "Edited", "Wrote", "Ran", "Searched", "Asked", "Delegated", "Show diff", "Change %lld of %lld this turn",
                    "← → the change before or after · Esc back to the list"]
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for key in keys {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty, Comment(rawValue: "\(language): \(key)"))
                if key.contains("%lld") { #expect(text.contains("%1$lld") && text.contains("%2$lld"), Comment(rawValue: "\(language): \(key)")) }
            }
        }
    }
}

@MainActor
struct AgentDiffTests {
    private func model() -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: "demo", with: AgentBoard.demoAgents())
        let model = AgentsTabModel(board: board, isConnected: { true })
        model.fixed = AgentBoard.demoTranscripts
        model.refresh()
        return model
    }

    @Test func aWorkingRowShowsItsLastStep() throws {
        let model = model()
        let row = try #require(model.rows.first { $0.title == "Agents tab" })
        #expect(row.showsActivity && row.activity?.edit == AgentBoard.demoEdit)
        #expect(row.edits.first?.added == 3 && row.edits.first?.removed == 2)
        // A row that asks shows its prompt instead.
        #expect(model.rows.filter(\.asksForAnswer).allSatisfy { !$0.showsActivity })
    }

    @Test func theArrowsStepThroughTheChangesAndStayInTheDiff() throws {
        let model = model()
        let row = try #require(model.rows.first { $0.title == "Agents tab" })
        #expect(!model.perform(.left))
        model.showDiff(row)
        #expect(model.diffing == AgentsTabModel.DiffFocus(id: row.id, index: 0))
        // Only one change: the arrows have nowhere to go but are still the diff's.
        #expect(model.perform(.left) && model.perform(.right))
        #expect(model.diffing?.index == 0)
        #expect(!model.perform(.message))
        model.closeDiff()
        #expect(model.diffing == nil)
    }

    @Test func aRowWithNoEditsHasNoDiff() throws {
        let model = model()
        let row = try #require(model.rows.first { $0.edits.isEmpty })
        model.showDiff(row)
        #expect(model.diffing == nil)
    }

    @Test func leavingTheTabClosesTheDiff() throws {
        let model = model()
        model.isShowing = true
        model.showDiff(try #require(model.rows.first { $0.title == "Agents tab" }))
        model.isShowing = false
        #expect(model.diffing == nil)
    }
}
