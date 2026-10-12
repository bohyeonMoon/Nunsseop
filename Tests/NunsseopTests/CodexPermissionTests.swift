import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Nunsseop

/// What Codex's PermissionRequest hook sends, as codex-cli 0.155 does.
enum CodexFixtures {
    static func body(tool: String = "Bash",
                     input: [String: Any] = ["command": "touch /Users/x/file.txt", "description": "May I create /Users/x/file.txt as requested?"],
                     cwd: String = "/Users/x/repo", extra: [String: Any] = [:]) -> Data {
        var json: [String: Any] = [
            "session_id": "01a130c4-0000-7000-8000-000000000001", "turn_id": "01a130c4-0000-7000-8000-000000000002",
            "transcript_path": "/Users/x/.codex/sessions/2026/10/13/rollout-1.jsonl", "cwd": cwd, "hook_event_name": "PermissionRequest",
            "model": "gpt-5.6-luna", "permission_mode": "default", "tool_name": tool, "tool_input": input]
        json.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    static func patch(_ lines: [String]) -> String { (["*** Begin Patch"] + lines + ["*** End Patch"]).joined(separator: "\n") }

    static func text(_ data: Data?) -> String { String(decoding: data ?? Data(), as: UTF8.self) }
}

struct CodexPermissionParseTests {
    private typealias F = CodexFixtures

    private func parse(_ body: Data) throws -> PermissionPrompt.Parsed { try #require(PermissionPrompt.parse(body)) }

    @Test func aCommandIsShownLikeClaudesWithItsDescriptionAndNoRuleToAdd() throws {
        let parsed = try parse(F.body())
        let prompt = parsed.prompt
        #expect(prompt.isCodex && prompt.title == "Run a command" && prompt.symbol == "terminal")
        #expect(prompt.detail == "touch /Users/x/file.txt")
        #expect(prompt.secondary == "description: May I create /Users/x/file.txt as requested?")
        #expect(prompt.folder == "repo" && prompt.grant == nil && prompt.asking == nil)
        #expect(parsed.suggestion == nil && parsed.questionInput == nil)
    }

    @Test func aCommandWithoutADescriptionHasNoSecondaryText() throws {
        let prompt = try parse(F.body(input: ["command": "ls -la"])).prompt
        #expect(prompt.isCodex && prompt.detail == "ls -la" && prompt.secondary.isEmpty && prompt.flags.isEmpty)
    }

    @Test func aPatchListsItsFilesFromTheHeadersAndThenShowsThePatch() throws {
        let patch = F.patch(["*** Add File: /Users/x/f.txt", "+hi", "*** Update File: /Users/x/a.swift", "*** Move to: /Users/x/b.swift",
                             "@@", "-old", "+new", "*** Delete File: /Users/x/gone.txt"])
        let prompt = try parse(F.body(tool: "apply_patch", input: ["command": patch])).prompt
        #expect(prompt.isCodex && prompt.title == "Edit files" && prompt.symbol == "pencil" && prompt.secondary.isEmpty)
        #expect(prompt.detail == """
            add /Users/x/f.txt
            update /Users/x/a.swift
            move to /Users/x/b.swift
            delete /Users/x/gone.txt
            patch:
            \(patch)
            """)
        #expect(prompt.grant == nil)
    }

    @Test func aPatchWithWindowsLineEndingsStillNamesItsFiles() throws {
        let patch = F.patch(["*** Add File: /a/b.txt", "+x"]).replacingOccurrences(of: "\n", with: "\r\n")
        let prompt = try parse(F.body(tool: "apply_patch", input: ["command": patch])).prompt
        #expect(prompt.detail.hasPrefix("add /a/b.txt\npatch:\n"))
    }

    @Test func aHeaderInsideTheContentOfAFileIsNotListedAsAFile() throws {
        let patch = F.patch(["*** Add File: /a/b.txt", "+*** Delete File: /etc/passwd"])
        let prompt = try parse(F.body(tool: "apply_patch", input: ["command": patch])).prompt
        #expect(prompt.detail.hasPrefix("add /a/b.txt\npatch:\n") && !prompt.detail.hasPrefix("add /a/b.txt\ndelete"))
    }

    @Test func aHeaderPaddedWithWhitespaceStillNamesItsFileAsCodexReadsIt() throws {
        // Codex trims every line before it reads a header, so these delete and add files.
        let patch = F.patch(["*** Add File: /a.txt", "+hi", "  *** Delete File: /victim.txt", "\u{A0}*** Add File: /b.txt", "+x",
                             "\t*** Update File: /c.txt", "\u{3000}\u{2003}*** Move to: /d.txt"])
        let prompt = try parse(F.body(tool: "apply_patch", input: ["command": patch])).prompt
        #expect(prompt.detail.hasPrefix("add /a.txt\ndelete /victim.txt\nadd /b.txt\nupdate /c.txt\nmove to /d.txt\npatch:\n"))
        let content = F.patch(["*** Add File: /a", "+  *** Delete File: /etc/passwd"])
        #expect(try parse(F.body(tool: "apply_patch", input: ["command": content])).prompt.detail.hasPrefix("add /a\npatch:\n"))
    }

    @Test func aPatchWithoutHeadersIsShownAsItIsAndOneWithoutTextIsShownAsAnyTool() throws {
        let bare = try parse(F.body(tool: "apply_patch", input: ["command": "garbled"])).prompt
        #expect(bare.title == "Edit files" && bare.detail == "garbled")
        let empty = try parse(F.body(tool: "apply_patch", input: ["command": ""])).prompt
        #expect(empty.title == "apply_patch" && empty.isCodex)
    }

    @Test func aPatchShowsItsOtherFieldsAndDescription() throws {
        let prompt = try parse(F.body(tool: "apply_patch", input: ["command": F.patch(["*** Add File: /a"]), "description": "Why", "extra": 1])).prompt
        #expect(prompt.secondary == "description: Why\nextra: 1")
    }

    @Test func anMCPToolShowsItsNameAndAllItsArguments() throws {
        let prompt = try parse(F.body(tool: "mcp__github__create_issue", input: ["title": "Bug", "labels": ["a"]])).prompt
        #expect(prompt.isCodex && prompt.title == "mcp__github__create_issue" && prompt.symbol == "puzzlepiece.extension")
        let shown = try #require(try JSONSerialization.jsonObject(with: Data(prompt.detail.utf8)) as? [String: Any])
        #expect(shown["title"] as? String == "Bug" && shown["labels"] as? [String] == ["a"])
        #expect(prompt.grant == nil)
    }

    @Test func aToolWithAClaudeCodeNameIsNotTakenForClaudeCodesTool() throws {
        let prompt = try parse(F.body(tool: "Read", input: ["file_path": "/etc/hosts"])).prompt
        #expect(prompt.title == "Read" && prompt.detail.contains("/etc/hosts") && prompt.detail.contains("file_path"))
        let write = try parse(F.body(tool: "Write", input: ["file_path": "/a", "content": "x"])).prompt
        #expect(write.title == "Write")
    }

    @Test func aToolWithoutInputStillAsksWithItsName() throws {
        let prompt = try parse(F.body(tool: "mcp__x__ping", input: [:])).prompt
        #expect(prompt.title == "mcp__x__ping" && prompt.detail.isEmpty)
    }

    @Test func nothingFromCodexIsOfferedAsAlwaysAllowEvenWhenItSendsSuggestions() throws {
        let parsed = try parse(F.body(extra: ["permission_suggestions": [PermissionTestServer.addRules]]))
        #expect(parsed.prompt.grant == nil && parsed.suggestion == nil)
    }

    @Test func whatCodexAsksPassesThroughTheSameEscapingAndChipAsClaudes() throws {
        let command = "echo \u{202E}x\u{200B}y; cat /etc/h\u{43E}sts"
        let prompt = try parse(F.body(input: ["command": command])).prompt
        #expect(prompt.detail.contains("⟨U+202E⟩") && prompt.detail.contains("⟨U+200B⟩") && prompt.detail.contains("⟨U+043E⟩"))
        let chip = try parse(F.body(input: ["command": "echo x ➕ y"])).prompt
        #expect(chip.flags.contains { $0.text == "Unusual characters" && $0.warns })
        let claude = try #require(PermissionPrompt.parse(PermissionTestServer.hookInput(input: ["command": command])))
        #expect(claude.prompt.detail == prompt.detail && claude.prompt.flags == prompt.flags)
        let patch = try parse(F.body(tool: "apply_patch", input: ["command": F.patch(["*** Add File: /a/\u{202E}b"])])).prompt
        #expect(patch.detail.contains("add /a/⟨U+202E⟩b"))
    }

    @Test func theLimitsOfClaudesPromptsApplyToCodexsToo() {
        let long = String(repeating: "x", count: PermissionPrompt.detailLimit + 1)
        #expect(PermissionPrompt.parse(F.body(input: ["command": long])) == nil)
        #expect(PermissionPrompt.parse(F.body(tool: String(repeating: "t", count: PermissionPrompt.titleLimit + 1), input: [:])) == nil)
        #expect(PermissionPrompt.parse(F.body(tool: "ExitPlanMode")) == nil)
        #expect(PermissionPrompt.parse(F.body(extra: ["hook_event_name": "Stop"])) == nil)
        #expect(PermissionPrompt.parse(F.body(tool: "")) == nil)
    }

    // MARK: Which tool sent it

    @Test func theTurnIdIsWhatMakesAPromptCodexs() throws {
        #expect(try parse(F.body()).prompt.isCodex)
        // Claude Code's input names no turn, whatever the folder of its transcript.
        let claude = PermissionTestServer.hookInput(input: ["command": "ls"])
        #expect(!(try parse(claude).prompt.isCodex))
        var withTranscript = try #require(try JSONSerialization.jsonObject(with: claude) as? [String: Any])
        withTranscript["transcript_path"] = "/Users/me/.claude/projects/-x/abc.jsonl"
        #expect(!(try parse(try JSONSerialization.data(withJSONObject: withTranscript)).prompt.isCodex))
        // A transcript under Codex's folder alone does not make it Codex's, and neither does an empty or odd turn id.
        withTranscript["transcript_path"] = "/Users/x/.codex/sessions/2026/10/13/rollout-1.jsonl"
        #expect(!(try parse(try JSONSerialization.data(withJSONObject: withTranscript)).prompt.isCodex))
        for turn: Any in ["", 7, NSNull()] {
            withTranscript["turn_id"] = turn
            #expect(!(try parse(try JSONSerialization.data(withJSONObject: withTranscript)).prompt.isCodex), "\(turn)")
        }
    }

    @Test func claudeCodesPromptsAreAsTheyWereWithTheirRuleToAdd() throws {
        let parsed = try parse(PermissionTestServer.hookInput(suggestions: [PermissionTestServer.addRules]))
        #expect(!parsed.prompt.isCodex && parsed.prompt.title == "Run a command" && parsed.prompt.detail == "npm run build")
        #expect(parsed.prompt.grant == PermissionPrompt.Grant(rules: ["Bash(npm run *)"], place: .localSettings) && parsed.suggestion != nil)
        let edit = try parse(PermissionTestServer.hookInput(tool: "Edit", input: ["file_path": "/a/b.swift"])).prompt
        #expect(edit.title == "Edit a file" && !edit.isCodex)
        // Claude's apply_patch-named tool, if one ever existed, is no Codex tool.
        let other = try parse(PermissionTestServer.hookInput(tool: "apply_patch", input: ["command": "x"])).prompt
        #expect(other.title == "apply_patch" && !other.isCodex)
    }

    // MARK: The decision

    @Test func codexIsAnsweredWithTheDecisionAndNothingItWouldRefuse() throws {
        let allow = try #require(PermissionWire.decision(.allow, suggestion: nil))
        let deny = try #require(PermissionWire.decision(.deny, suggestion: nil))
        #expect(String(decoding: allow, as: UTF8.self)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(String(decoding: deny, as: UTF8.self)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied in Nunsseop"},"hookEventName":"PermissionRequest"}}"#)
        for data in [allow, deny] {
            let text = String(decoding: data, as: UTF8.self)
            for reserved in ["updatedPermissions", "updatedInput", "interrupt"] { #expect(!text.contains(reserved)) }
        }
        // Nothing is said for the terminal, and "Always allow" has nothing to echo for a prompt that has no rule.
        #expect(PermissionWire.decision(.terminal, suggestion: nil) == nil)
        #expect(PermissionWire.decision(.always, suggestion: nil) == nil)
        #expect(PermissionWire.decision(.answered([0: [0]]), suggestion: nil) == nil)
    }
}

@MainActor
struct CodexPermissionBoardTests {
    private func prompt() throws -> PermissionPrompt { try #require(PermissionPrompt.parse(CodexFixtures.body())).prompt }

    @Test func theTerminalButtonIsGatedLikeEveryOtherButton() throws {
        let clock = PermissionBoardTests.Clock()
        let board = PermissionBoard(gate: PermissionClickGate(clock: { clock.now }))
        var answers: [PermissionAnswer] = []
        board.onAnswer = { answers.append($1) }
        let codex = try prompt()
        board.add(codex)
        board.gate.pressBegan()
        board.answerByClick(codex, .terminal)
        #expect(answers.isEmpty && board.current == codex)
        clock.now += PermissionClickGate.delay + 0.01
        board.gate.pressBegan()
        clock.now += 0.1
        board.answerByClick(codex, .terminal)
        #expect(answers == [.terminal] && board.current == nil)
    }

    @Test func aClickBeginningBeforeTheDelayEndedDoesNotHandItBack() throws {
        let clock = PermissionBoardTests.Clock()
        let board = PermissionBoard(gate: PermissionClickGate(clock: { clock.now }))
        var answers = 0
        board.onAnswer = { _, _ in answers += 1 }
        let codex = try prompt()
        board.add(codex)
        clock.now += 0.3
        board.gate.pressBegan()
        clock.now += 2
        board.answerByClick(codex, .terminal)
        #expect(answers == 0 && board.current == codex)
    }

    @Test func theNextCodexCardInTheQueueGetsTheDelayAgain() throws {
        let clock = PermissionBoardTests.Clock()
        let board = PermissionBoard(gate: PermissionClickGate(clock: { clock.now }))
        board.onAnswer = { _, _ in }
        let first = try prompt(), second = try prompt()
        board.add(first)
        board.add(second)
        clock.now += 1
        board.answerByClick(first, .allow)
        #expect(board.current == second && !board.gate.isReady)
    }
}

@MainActor
struct CodexPermissionLayoutTests {
    private func fitting<V: View>(_ view: V, width: CGFloat) -> CGSize {
        NSHostingView(rootView: view.frame(width: width)).fittingSize
    }

    private func prompt(_ command: String, codex: Bool, grant: PermissionPrompt.Grant? = nil, title: String = "Run a command") -> PermissionPrompt {
        PermissionPrompt(id: UUID(), title: title, symbol: "terminal", detail: command, folder: "proj", grant: grant, codex: codex)
    }

    private let details = ["", "ls", "a\nb\nc\nd", String(repeating: "line of text\n", count: 30), String(repeating: "x", count: 900)]

    @Test func theCardIsOneButtonRowTallerForCodexAndIsSizedAsDrawn() {
        let gate = PermissionClickGate()
        for detail in details {
            for hasNotch in [true, false] {
                let codex = prompt(detail, codex: true), claude = prompt(detail, codex: false)
                let view = PermissionBody(prompt: codex, showsTitle: hasNotch, stacked: true, place: .card, gate: gate) { _ in }
                    .padding(.horizontal, 6)
                let drawn = fitting(view, width: PermissionLayout.Place.card.width + 12).height + PermissionLayout.bottomPad
                let sized = PermissionCard.bodyHeight(for: codex, hasNotch: hasNotch)
                #expect(abs(drawn - sized) <= 1, "\(detail.count) characters, notch \(hasNotch): drawn \(drawn), sized \(sized)")
                #expect(abs(sized - PermissionCard.bodyHeight(for: claude, hasNotch: hasNotch)
                            - PermissionLayout.buttonHeight - PermissionLayout.gap) <= 0.01)
            }
        }
    }

    @Test func thePanelKeepsOneRowOfThreeButtonsAndIsSizedAsDrawn() {
        let gate = PermissionClickGate()
        for detail in details {
            let codex = prompt(detail, codex: true)
            let view = PermissionPanel(prompt: codex, count: 1, gate: gate) { _ in }
            let drawn = fitting(view, width: PermissionLayout.Place.panel.width).height
            #expect(abs(drawn - PermissionPanel.height(for: codex)) <= 1, "\(detail.count) characters: drawn \(drawn), sized \(PermissionPanel.height(for: codex))")
            #expect(PermissionPanel.height(for: codex) == PermissionPanel.height(for: prompt(detail, codex: false)))
        }
    }

    @Test func aCodexPromptNeverHasAnAlwaysAllowRowEvenWhenGivenARule() {
        let grant = PermissionPrompt.Grant(rules: ["Bash(a:*)"], place: .session)
        let codex = prompt("ls", codex: true, grant: grant)
        #expect(PermissionLayout.hasThirdButton(codex, .card) && PermissionLayout.hasThirdButton(prompt("ls", codex: false, grant: grant), .card))
        #expect(!PermissionLayout.hasThirdButton(prompt("ls", codex: false), .card) && PermissionLayout.hasThirdButton(prompt("ls", codex: true), .panel))
    }

    @Test func theLabelIsMeasuredIntoTheTitleLineAndNothingFittingIsCut() {
        for unit in ["m", "W", "i", "한"] {
            for folder in ["", "proj"] {
                let claudeLongest = (1...200).last { PermissionLayout.titleFits(String(repeating: unit, count: $0), folder: folder) } ?? 0
                let codexLongest = (1...200).last { PermissionLayout.titleFits(String(repeating: unit, count: $0), folder: folder, codex: true) } ?? 0
                #expect(codexLongest > 0 && codexLongest < claudeLongest, "\(unit)")
                let title = String(repeating: unit, count: codexLongest)
                let fits = PermissionPrompt(id: UUID(), title: title, symbol: "terminal", detail: "", folder: folder, grant: nil, codex: true)
                #expect(fits.toolLine.isEmpty)
                let width = NSHostingView(rootView: PermissionTitle(prompt: fits)).fittingSize.width
                #expect(width <= PermissionLayout.titleRoom + PermissionLayout.titleMargin, "\(unit) x\(codexLongest) \(folder): \(width)")
                let more = PermissionPrompt(id: UUID(), title: title + unit, symbol: "terminal", detail: "", folder: folder, grant: nil, codex: true)
                #expect(more.toolLine == "tool: " + title + unit)
            }
        }
    }
}

struct PermissionSettingToolsTests {
    @Test func aToolIsExplainedOnlyWhenItIsOnThisMac() {
        #expect(NotifyIntegration.askingForPermission(present: [.codex]) == [.codex])
        #expect(NotifyIntegration.askingForPermission(present: [.claudeCode]) == [.claudeCode])
        #expect(NotifyIntegration.askingForPermission(present: [.claudeCode, .codex, .openCode]) == [.claudeCode, .codex])
        #expect(NotifyIntegration.askingForPermission(present: [.openCode]).isEmpty)
    }
}
