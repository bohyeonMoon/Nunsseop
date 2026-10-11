import CryptoKit
import Foundation
import Testing
@testable import Nunsseop

struct PermissionWireTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theProofIsAnHMACOverTheDomainTheNonceAndTheBodysDigest() {
        let token = String(repeating: "ab", count: 32), nonce = String(repeating: "0f", count: 16)
        let body = Data("{\"tool_name\":\"Bash\"}".utf8)
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = Data("nunsseop-permission-request\n\(nonce)\n\(digest)".utf8)
        let expected = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(token.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        #expect(PermissionWire.requestProof(token: token, nonce: nonce, body: body) == expected)
        #expect(expected.count == 64)
    }

    @Test func requestAndResponseProofsAreBoundToTheirDomainAndNonce() {
        let token = String(repeating: "cd", count: 32), nonce = String(repeating: "1a", count: 16)
        let other = String(repeating: "2b", count: 16)
        let bytes = Data("same bytes".utf8)
        let request = PermissionWire.requestProof(token: token, nonce: nonce, body: bytes)
        let response = PermissionWire.responseProof(token: token, nonce: nonce, decision: bytes)
        #expect(request != response)
        #expect(response != PermissionWire.responseProof(token: token, nonce: other, decision: bytes))
        #expect(response != PermissionWire.responseProof(token: token + "0", nonce: nonce, decision: bytes))
        #expect(response != PermissionWire.responseProof(token: token, nonce: nonce, decision: bytes + [0x20]))
    }

    @Test func aNonceIsSixteenBytesOfLowercaseHex() {
        #expect(PermissionWire.isNonce(String(repeating: "0a", count: 16)))
        for bad in ["", String(repeating: "0a", count: 15), String(repeating: "0a", count: 17), String(repeating: "0A", count: 16),
                    String(repeating: "g0", count: 16), String(repeating: "0a", count: 15) + "0\n"] {
            #expect(!PermissionWire.isNonce(bad), "\(bad)")
        }
    }

    @Test func theDecisionsAreExactlyWhatClaudeCodeReads() throws {
        let prefix = #"{"hookSpecificOutput":{"decision":{"#
        let suffix = #"},"hookEventName":"PermissionRequest"}}"#
        #expect(String(decoding: try #require(PermissionWire.decision(.allow, suggestion: nil)), as: UTF8.self)
                == prefix + #""behavior":"allow""# + suffix)
        #expect(String(decoding: try #require(PermissionWire.decision(.deny, suggestion: nil)), as: UTF8.self)
                == prefix + #""behavior":"deny","message":"Denied in Nunsseop""# + suffix)
    }

    @Test func alwaysAllowEchoesTheOneSuggestionAndNeedsOne() throws {
        let data = try #require(PermissionWire.decision(.always, suggestion: PermissionTestServer.addRules))
        let decision = try #require((try json(data)["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let updated = try #require(decision["updatedPermissions"] as? [[String: Any]])
        #expect(updated.count == 1)
        #expect(NSDictionary(dictionary: updated[0]).isEqual(to: PermissionTestServer.addRules))
        #expect(!String(decoding: data, as: UTF8.self).contains("setMode"))
        #expect(PermissionWire.decision(.always, suggestion: nil) == nil)
    }

    @Test func aDecisionIsOneLineEvenForAnAwkwardRule() throws {
        let rule: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                   "rules": [["toolName": "Bash", "ruleContent": "echo \"a\\b\"\n100% $HOME `x`"]]]
        let data = try #require(PermissionWire.decision(.always, suggestion: rule))
        #expect(!data.contains(0x0a))
    }
}

struct PermissionPromptParseTests {
    private func parse(_ tool: String, _ input: [String: Any], cwd: String = "/Users/me/proj",
                       suggestions: [[String: Any]]? = nil) -> PermissionPrompt.Parsed? {
        PermissionPrompt.parse(PermissionTestServer.hookInput(tool: tool, input: input, cwd: cwd, suggestions: suggestions))
    }

    @Test func aCommandIsShownWithItsFolderAndTheRuleItWouldAdd() throws {
        let parsed = try #require(parse("Bash", ["command": "npm run build"], suggestions: [PermissionTestServer.addRules]))
        #expect(parsed.prompt.title == "Run a command")
        #expect(parsed.prompt.detail == "npm run build")
        #expect(parsed.prompt.folder == "proj")
        #expect(parsed.prompt.rule == "Bash(npm run *)")
        #expect(parsed.prompt.symbol == "terminal")
        #expect(parsed.suggestion != nil)
    }

    @Test func fileAndWebToolsSayWhatTheyDoInPlainWords() throws {
        let cases: [(String, [String: Any], String, String)] = [
            ("Edit", ["file_path": "/a/b.swift"], "Edit a file", "/a/b.swift"),
            ("MultiEdit", ["file_path": "/a/c.swift"], "Edit a file", "/a/c.swift"),
            ("Write", ["file_path": "/a/new.txt", "content": "secret body"], "Write a file", "/a/new.txt"),
            ("NotebookEdit", ["notebook_path": "/a/n.ipynb"], "Edit a notebook", "/a/n.ipynb"),
            ("Read", ["file_path": "/etc/hosts"], "Read a file", "/etc/hosts"),
            ("WebFetch", ["url": "https://example.com/x"], "Fetch a web page", "https://example.com/x"),
            ("WebSearch", ["query": "swift nio"], "Search the web", "swift nio"),
        ]
        for (tool, input, title, detail) in cases {
            let parsed = try #require(parse(tool, input), "\(tool)")
            #expect(parsed.prompt.title == title && parsed.prompt.detail == detail, "\(tool)")
        }
    }

    @Test func anMCPToolShowsItsServerAndName() throws {
        let parsed = try #require(parse("mcp__github__create_issue", ["title": "Bug"]))
        #expect(parsed.prompt.title == "github · create_issue")
        #expect(parsed.prompt.detail == #"{"title":"Bug"}"#)
        #expect(try #require(parse("mcp__a__b__c", [:])).prompt.title == "a · b__c")
        #expect(try #require(parse("Task", ["description": "x"])).prompt.title == "Task")
        #expect(try #require(parse("mcp__a__b", [:])).prompt.detail.isEmpty)
    }

    @Test func questionsPlansAndNonsenseAreLeftToTheTerminal() {
        #expect(parse("AskUserQuestion", ["questions": []]) == nil)
        #expect(parse("ExitPlanMode", ["plan": "x"]) == nil)
        #expect(PermissionPrompt.parse(Data("not json".utf8)) == nil)
        #expect(PermissionPrompt.parse(Data()) == nil)
        let other = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "tool_name": "Bash"])
        #expect(PermissionPrompt.parse(other) == nil)
        let nameless = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest"])
        #expect(PermissionPrompt.parse(nameless) == nil)
    }

    @Test func aModeChangeIsNeverTheRuleOffered() throws {
        let deny: [String: Any] = ["type": "addRules", "behavior": "deny", "rules": [["toolName": "Bash"]]]
        let empty: [String: Any] = ["type": "addRules", "behavior": "allow", "rules": []]
        let only = try #require(parse("Bash", ["command": "ls"], suggestions: [PermissionTestServer.setMode, deny, empty]))
        #expect(only.prompt.rule == nil && only.suggestion == nil)

        let both = try #require(parse("Bash", ["command": "ls"], suggestions: [PermissionTestServer.setMode, PermissionTestServer.addRules]))
        #expect(both.prompt.rule == "Bash(npm run *)")
        #expect(both.suggestion?["type"] as? String == "addRules")
    }

    @Test func aRuleWithoutContentOrWithSeveralPartsReadsAsClaudeCodeWritesIt() throws {
        let rules: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "session",
                                    "rules": [["toolName": "WebFetch"], ["toolName": "Read", "ruleContent": "/a/**"], ["noName": 1]]]
        #expect(try #require(parse("WebFetch", ["url": "https://x.y"], suggestions: [rules])).prompt.rule == "WebFetch, Read(/a/**)")
    }

    @Test func textIsOneCleanLineAndTruncated() {
        #expect(PermissionPrompt.clean("a\n\tb   c\r\nd", limit: 100) == "a b c d")
        #expect(PermissionPrompt.clean("  lead and trail \n", limit: 100) == "lead and trail")
        // Direction overrides and zero-width characters can't make a command read as another.
        #expect(PermissionPrompt.clean("rm\u{202E} -rf\u{200B} /", limit: 100) == "rm -rf /")
        let long = String(repeating: "x", count: 500)
        let cut = PermissionPrompt.clean(long, limit: 400)
        #expect(cut.count == 400 && cut.hasSuffix("…"))
        #expect(PermissionPrompt.clean(String(repeating: "y", count: 400), limit: 400).count == 400)
        #expect(!PermissionPrompt.clean(String(repeating: "y", count: 400), limit: 400).hasSuffix("…"))
    }

    @Test func theTooltipKeepsMoreThanTheLine() throws {
        let parsed = try #require(parse("Bash", ["command": String(repeating: "a ", count: 600)]))
        #expect(parsed.prompt.detail.count == PermissionPrompt.detailLimit)
        #expect(parsed.prompt.fullDetail.count > parsed.prompt.detail.count)
        #expect(parsed.prompt.fullDetail.count <= PermissionPrompt.fullLimit)
    }
}

@MainActor
struct PermissionBoardTests {
    private func prompt(_ detail: String) -> PermissionPrompt {
        PermissionPrompt(id: UUID(), title: "Run a command", symbol: "terminal", detail: detail, fullDetail: detail,
                         folder: "proj", rule: nil)
    }

    @Test func promptsQueueOldestFirstAndEachIsAnsweredOnce() {
        let board = PermissionBoard()
        var answers: [(UUID, PermissionAnswer)] = []
        board.onAnswer = { answers.append(($0, $1)) }
        let first = prompt("one"), second = prompt("two")
        board.add(first)
        board.add(second)
        #expect(board.current == first && board.prompts.count == 2)
        board.answer(first, .allow)
        board.answer(first, .deny)
        #expect(board.current == second)
        #expect(answers.count == 1 && answers[0].0 == first.id && answers[0].1 == .allow)
    }

    @Test func aHookThatIsGoneTakesItsPromptAwayWithoutAnAnswer() {
        let board = PermissionBoard()
        var answers = 0
        board.onAnswer = { _, _ in answers += 1 }
        let first = prompt("one"), second = prompt("two")
        board.add(first)
        board.add(second)
        board.remove(first.id)
        #expect(board.prompts == [second])
        board.answer(first, .allow)
        #expect(answers == 0)
        board.clear()
        #expect(board.current == nil)
    }

    @Test func theClosedNotchGrowsForAPromptWhateverElseItShows() {
        let notch = CGSize(width: 200, height: 32), brow = CGSize(width: 44, height: 18)
        let live = HUDEvent.notice(symbol: "bolt", title: "Hi", detail: nil)
        for (base, hasNotch) in [(notch, true), (brow, false)] {
            let plain = NotchViewModel.collapsedSize(base: base, hasNotch: hasNotch, screenWidth: 1440, event: nil, showsLiveActivity: false,
                                                     earWidth: 38, idleGrowth: nil, showsSneakPeek: false, inlinePeekWidth: 240)
            let asked = NotchViewModel.collapsedSize(base: base, hasNotch: hasNotch, screenWidth: 1440, event: live, showsLiveActivity: true,
                                                     earWidth: 38, idleGrowth: 140, showsSneakPeek: true, inlinePeekWidth: 240,
                                                     approvalHeight: 90)
            #expect(asked.height == plain.height + 90)
            #expect(asked.width >= NotchViewModel.approvalWidth)
        }
    }

    @Test func theCardIsTallerForARuleAndForAnOpenTitleLine() {
        func height(rule: String?, hasNotch: Bool) -> CGFloat {
            PermissionCard.bodyHeight(for: PermissionPrompt(id: UUID(), title: "t", symbol: "terminal", detail: "d", fullDetail: "d",
                                                            folder: "f", rule: rule), hasNotch: hasNotch)
        }
        #expect(height(rule: "Bash(ls)", hasNotch: true) > height(rule: nil, hasNotch: true))
        #expect(height(rule: nil, hasNotch: true) > height(rule: nil, hasNotch: false))
    }
}
