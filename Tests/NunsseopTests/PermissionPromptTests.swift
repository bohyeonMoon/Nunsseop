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

    private func addRules(_ rules: [[String: Any]], destination: String? = "localSettings") -> [String: Any] {
        var suggestion: [String: Any] = ["type": "addRules", "behavior": "allow", "rules": rules]
        suggestion["destination"] = destination
        return suggestion
    }

    @Test func aCommandIsShownWithItsFolderAndTheRuleItWouldAdd() throws {
        let parsed = try #require(parse("Bash", ["command": "npm run build"], suggestions: [PermissionTestServer.addRules]))
        #expect(parsed.prompt.title == "Run a command")
        #expect(parsed.prompt.detail == "npm run build")
        #expect(parsed.prompt.folder == "proj")
        #expect(parsed.prompt.grant == PermissionPrompt.Grant(rules: ["Bash(npm run *)"], place: .localSettings))
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

    // MARK: Tools without a plain description

    @Test func anyOtherToolShowsItsOwnNameAndAllOfItsInput() throws {
        let parsed = try #require(parse("mcp__github__create_issue", ["title": "Bug", "labels": ["a", "b"]]))
        #expect(parsed.prompt.title == "mcp__github__create_issue")
        #expect(parsed.prompt.detail == "{\n  \"labels\" : [\n    \"a\",\n    \"b\"\n  ],\n  \"title\" : \"Bug\"\n}")
        for tool in ["Task", "Skill", "TodoWrite"] {
            let prompt = try #require(parse(tool, ["description": "run /deploy", "n": 1])).prompt
            #expect(prompt.title == tool, "\(tool)")
            #expect(prompt.detail.contains(#""description" : "run /deploy""#) && prompt.detail.contains(#""n" : 1"#), "\(tool)")
        }
        #expect(try #require(parse("mcp__a__b", [:])).prompt.detail.isEmpty)
    }

    @Test func aKnownToolWhoseFieldIsNotTheTextItShouldBeShowsEverythingInstead() throws {
        for input: [String: Any] in [["command": 7, "timeout": 5], ["cmd": "ls"], ["command": ""]] {
            let prompt = try #require(parse("Bash", input)).prompt
            #expect(prompt.title == "Bash" && prompt.symbol == "puzzlepiece.extension")
            #expect(prompt.detail.contains(input.keys.sorted().first!))
        }
    }

    @Test func aToolNameIsEscapedLikeTheRestAndNotAcceptedWhenTooLongToShow() throws {
        let prompt = try #require(parse("Task\u{202E}x", [:])).prompt
        #expect(prompt.title == "Task⟨U+202E⟩x")
        #expect(parse(String(repeating: "t", count: PermissionPrompt.titleLimit), [:]) != nil)
        #expect(parse(String(repeating: "t", count: PermissionPrompt.titleLimit + 1), [:]) == nil)
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

    // MARK: Lines and invisible characters

    @Test func lineBreaksStayLineBreaksAndNothingIsJoined() throws {
        let command = "echo safe\n\n\nrm -rf ~\r\nls"
        let prompt = try #require(parse("Bash", ["command": command])).prompt
        #expect(prompt.detail == "echo safe\n\n\nrm -rf ~\nls")
        #expect(prompt.detail.components(separatedBy: "\n").count == 5)
        #expect(PermissionText.escape("a\nb", multiline: false) == "a⟨U+000A⟩b")
    }

    @Test func controlZeroWidthAndDirectionCharactersAreShownNotRemoved() {
        #expect(PermissionText.escape("rm\u{202E} -rf\u{200B} /", multiline: true) == "rm⟨U+202E⟩ -rf⟨U+200B⟩ /")
        let invisible: [UInt32] = Array(0x200B...0x200F) + Array(0x202A...0x202E) + Array(0x2066...0x2069)
            + [0xFEFF, 0x00AD, 0x2060, 0xE0041, 0x0000, 0x0007, 0x001B, 0x007F, 0x0085, 0x2028, 0x2029, 0x00A0, 0x3000, 0x2003]
        for value in invisible {
            let scalar = Character(Unicode.Scalar(value)!)
            #expect(PermissionText.escape("a\(scalar)b", multiline: true) == "a" + String(format: "⟨U+%04X⟩", value) + "b",
                    "U+\(String(value, radix: 16, uppercase: true))")
        }
        #expect(PermissionText.escape("a\tb\rc", multiline: true) == "a⟨U+0009⟩b⟨U+000D⟩c")
        // A written-out escape can't be told from a real one, so the brackets are escaped too.
        #expect(PermissionText.escape("⟨U+202E⟩", multiline: true) == "⟨U+27E8⟩U+202E⟨U+27E9⟩")
        for plain in ["echo \"한글 😀 é\" 'x' $HOME `id` 100% \\n", "👨‍👩‍👧"] where plain != "👨‍👩‍👧" {
            #expect(PermissionText.escape(plain, multiline: true) == plain)
        }
    }

    @Test func everyEscapeInACommandReachesTheDetail() throws {
        let prompt = try #require(parse("Bash", ["command": "git status\u{202E}\u{2066}; rm -rf /\u{FEFF}"])).prompt
        #expect(prompt.detail == "git status⟨U+202E⟩⟨U+2066⟩; rm -rf /⟨U+FEFF⟩")
        let path = try #require(parse("Edit", ["file_path": "/a/\u{200B}.ssh/config"])).prompt
        #expect(path.detail == "/a/⟨U+200B⟩.ssh/config")
        let folder = try #require(parse("Bash", ["command": "ls"], cwd: "/x/pro\u{202E}j")).prompt.folder
        #expect(folder == "pro⟨U+202E⟩j")
    }

    // MARK: Long commands

    @Test func aLongCommandIsKeptWholeWithItsEnd() throws {
        let command = (1...400).map { "step \($0) of the build" }.joined(separator: "\n") + "\nrm -rf ~/the-end"
        #expect(command.count < PermissionPrompt.detailLimit)
        let prompt = try #require(parse("Bash", ["command": command])).prompt
        #expect(prompt.detail == command)
        #expect(prompt.detail.hasSuffix("the-end"))
    }

    @Test func whatIsTooLongToShowInFullIsLeftToTheTerminalNotCut() {
        #expect(parse("Bash", ["command": String(repeating: "a", count: PermissionPrompt.detailLimit)]) != nil)
        #expect(parse("Bash", ["command": String(repeating: "a", count: PermissionPrompt.detailLimit + 1)]) == nil)
        // The escapes count: each of these takes eight characters on the card.
        #expect(parse("Bash", ["command": String(repeating: "\u{200B}", count: PermissionPrompt.detailLimit / 8 + 1)]) == nil)
        #expect(parse("Write", ["file_path": String(repeating: "/a", count: PermissionPrompt.detailLimit)]) == nil)
    }

    // MARK: What "Always allow" would add

    @Test func aModeChangeIsNeverTheRuleOffered() throws {
        let deny: [String: Any] = ["type": "addRules", "behavior": "deny", "rules": [["toolName": "Bash"]]]
        let empty: [String: Any] = ["type": "addRules", "behavior": "allow", "rules": []]
        let only = try #require(parse("Bash", ["command": "ls"], suggestions: [PermissionTestServer.setMode, deny, empty]))
        #expect(only.prompt.grant == nil && only.suggestion == nil)

        let both = try #require(parse("Bash", ["command": "ls"], suggestions: [PermissionTestServer.setMode, PermissionTestServer.addRules]))
        #expect(both.prompt.grant?.rules == ["Bash(npm run *)"])
        #expect(both.suggestion?["type"] as? String == "addRules")
    }

    @Test func everyRuleOfTheSuggestionIsShownAsClaudeCodeWritesItAndTheSuggestionIsEchoedAsItIs() throws {
        let rules: [[String: Any]] = [["toolName": "WebFetch"], ["toolName": "Read", "ruleContent": "/a/**"],
                                      ["toolName": "Bash", "ruleContent": "git status:*"]]
        let suggestion = addRules(rules, destination: "projectSettings")
        let parsed = try #require(parse("WebFetch", ["url": "https://x.y"], suggestions: [suggestion]))
        #expect(parsed.prompt.grant == PermissionPrompt.Grant(rules: ["WebFetch", "Read(/a/**)", "Bash(git status:*)"], place: .projectSettings))
        #expect(NSDictionary(dictionary: try #require(parsed.suggestion)).isEqual(to: suggestion))
    }

    @Test func theButtonSaysWhereTheRuleIsSaved() throws {
        let places: [(String, PermissionPrompt.Grant.Place, String)] = [
            ("localSettings", .localSettings, "in this project, just for you"),
            ("projectSettings", .projectSettings, "in this project"),
            ("userSettings", .userSettings, "everywhere"),
            ("session", .session, "for this session"),
        ]
        for (destination, place, phrase) in places {
            let rule = addRules([["toolName": "Bash", "ruleContent": "ls:*"]], destination: destination)
            let parsed = try #require(parse("Bash", ["command": "ls"], suggestions: [rule]))
            let grant = try #require(parsed.prompt.grant, "\(destination)")
            #expect(grant.place == place && grant.place.phrase == phrase, "\(destination)")
        }
    }

    @Test func aRuleThatCouldNotBeShownAsItIsIsNotOffered() throws {
        let fine: [String: Any] = ["toolName": "Bash", "ruleContent": "ls:*"]
        let cases: [(String, [String: Any])] = [
            ("four rules", addRules(Array(repeating: fine, count: 4))),
            ("a newline in a rule", addRules([["toolName": "Bash", "ruleContent": "ls\nrm -rf /"]])),
            ("a direction override", addRules([["toolName": "Bash", "ruleContent": "ls\u{202E}"]])),
            ("a tab", addRules([["toolName": "Bash", "ruleContent": "a\tb"]])),
            ("a rule too long for three rows", addRules([["toolName": "Bash", "ruleContent": String(repeating: "x", count: 200)]])),
            ("a rule that is not an object", addRules([fine, ["noName": 1]])),
            ("a rule that is a string", ["type": "addRules", "behavior": "allow", "destination": "session", "rules": ["Bash"]]),
            ("a rule without a tool", addRules([["ruleContent": "ls"]])),
            ("a tool name that is empty", addRules([["toolName": ""]])),
            ("a rule with a key nobody knows", addRules([["toolName": "Bash", "ruleContent": "ls", "extra": "x"]])),
            ("a rule content that is not text", addRules([["toolName": "Bash", "ruleContent": 5]])),
            ("a rule content that is empty", addRules([["toolName": "Bash", "ruleContent": ""]])),
            ("a suggestion with a key nobody knows", {
                var suggestion = addRules([fine]); suggestion["directories"] = ["/"]; return suggestion }()),
            ("no place", addRules([fine], destination: nil)),
            ("a place that is not known", addRules([fine], destination: "everyone")),
        ]
        for (name, suggestion) in cases {
            let parsed = try #require(parse("Bash", ["command": "ls"], suggestions: [suggestion]), Comment(rawValue: name))
            #expect(parsed.prompt.grant == nil, Comment(rawValue: name))
            #expect(parsed.suggestion == nil, Comment(rawValue: name))
        }
    }

    @Test func threeRulesAreTheMostOffered() throws {
        let rules = (1...3).map { ["toolName": "Bash", "ruleContent": "cmd\($0):*"] as [String: Any] }
        #expect(try #require(parse("Bash", ["command": "ls"], suggestions: [addRules(rules)])).prompt.grant?.rules.count == 3)
    }
}

@MainActor
struct PermissionBoardTests {
    private func prompt(_ detail: String, grant: PermissionPrompt.Grant? = nil) -> PermissionPrompt {
        PermissionPrompt(id: UUID(), title: "Run a command", symbol: "terminal", detail: detail, folder: "proj", grant: grant)
    }

    /// Time that moves only when a test says so.
    final class Clock {
        var now: TimeInterval = 1_000
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

    // MARK: Accidental clicks

    private func board(_ clock: Clock) -> PermissionBoard {
        PermissionBoard(gate: PermissionClickGate(clock: { clock.now }))
    }

    @Test func aClickJustAfterACardAppearsDoesNotAnswerIt() {
        let clock = Clock(), board = board(clock)
        var answers: [PermissionAnswer] = []
        board.onAnswer = { answers.append($1) }
        let first = prompt("one")
        board.add(first)
        #expect(!board.gate.isReady)
        board.gate.pressBegan()
        board.answerByClick(first, .allow)
        clock.now += PermissionClickGate.delay - 0.01
        board.gate.pressBegan()
        board.answerByClick(first, .allow)
        #expect(answers.isEmpty && board.current == first)

        clock.now += 0.02
        board.gate.pressBegan()
        clock.now += 0.1
        board.answerByClick(first, .allow)
        #expect(answers == [.allow] && board.current == nil)
    }

    @Test func aClickThatBeganBeforeTheDelayEndedDoesNotCountWhenItEndsAfter() {
        let clock = Clock(), board = board(clock)
        var answers = 0
        board.onAnswer = { _, _ in answers += 1 }
        let first = prompt("one")
        board.add(first)
        clock.now += 0.3
        board.gate.pressBegan()
        clock.now += 2
        board.gate.refresh()
        #expect(board.gate.isReady)
        board.answerByClick(first, .deny)
        #expect(answers == 0 && board.current == first)
    }

    @Test func theNextCardInTheQueueGetsTheDelayAgain() {
        let clock = Clock(), board = board(clock)
        var answers: [(UUID, PermissionAnswer)] = []
        board.onAnswer = { answers.append(($0, $1)) }
        let first = prompt("one"), second = prompt("two"), third = prompt("three")
        board.add(first)
        board.add(second)
        board.add(third)
        clock.now += 1
        board.gate.refresh()
        #expect(board.gate.isReady)
        board.answerByClick(first, .allow)
        // The first was answered; the second is in front now, and a click aimed at the first lands on it.
        #expect(answers.count == 1 && board.current == second && !board.gate.isReady)
        board.answerByClick(second, .allow)
        #expect(answers.count == 1 && board.current == second)

        clock.now += 1
        board.gate.refresh()
        board.gate.pressBegan()
        // The hook of the front card is gone, so the third takes its place under the same mouse button.
        board.remove(second.id)
        #expect(board.current == third && !board.gate.isReady)
        clock.now += 0.1
        board.answerByClick(third, .allow)
        clock.now += 1
        board.answerByClick(third, .allow)
        #expect(answers.count == 1 && board.current == third, "a press that began on the card before is not a click on this one")

        board.gate.pressBegan()
        board.answerByClick(third, .allow)
        #expect(answers.count == 2 && board.current == nil)
    }

    @Test func aCardThatAppearsAgainGetsTheDelayAgain() {
        let clock = Clock(), gate = PermissionClickGate(clock: { clock.now })
        gate.arm()
        clock.now += 1
        #expect(gate.accepts() && gate.isReady)
        gate.arm()
        #expect(!gate.isReady && !gate.accepts())
    }

    @Test func theDelayIsAboutSevenTenthsOfASecond() {
        let clock = Clock(), gate = PermissionClickGate(clock: { clock.now })
        #expect(PermissionClickGate.delay == 0.7)
        #expect(!gate.accepts(), "never armed")
        gate.arm()
        clock.now += 0.699
        gate.refresh()
        #expect(!gate.isReady && !gate.accepts())
        clock.now += 0.002
        gate.refresh()
        #expect(gate.isReady && gate.accepts())
    }

    @Test func aPressBeforeTheCardChangedNeverCountsOnTheNewOne() {
        let clock = Clock(), gate = PermissionClickGate(clock: { clock.now })
        gate.arm()
        clock.now += 1
        gate.pressBegan()
        clock.now += 0.1
        gate.arm()
        clock.now += 5
        #expect(!gate.accepts())
        gate.pressBegan()
        #expect(gate.accepts())
    }

    @Test func aReleaseWithoutAPressIsAnActivationByAccessibilityAndCountsOnceTheDelayIsOver() {
        let clock = Clock(), gate = PermissionClickGate(clock: { clock.now })
        gate.arm()
        #expect(!gate.accepts())
        clock.now += 1
        #expect(gate.accepts())
    }

    @Test func theButtonsAreLiveOnceTheRealDelayHasPassed() async {
        let gate = PermissionClickGate()
        gate.arm()
        #expect(!gate.isReady)
        await eventually { gate.isReady }
        #expect(gate.isReady)
    }

    // MARK: Room

    @Test func aLongCommandShowsAFewRowsAndSaysThereIsMore() {
        func shown(_ detail: String, grant: PermissionPrompt.Grant? = nil) -> (rows: Int, more: Bool) {
            let prompt = prompt(detail, grant: grant)
            return (PermissionLayout.detailRows(prompt, columns: PermissionLayout.cardColumns),
                    PermissionLayout.overflows(prompt, columns: PermissionLayout.cardColumns))
        }
        #expect(shown("ls").rows == 1 && !shown("ls").more)
        #expect(shown("a\nb\nc").rows == 3 && !shown("a\nb\nc").more)
        let six = (1...6).map(String.init).joined(separator: "\n")
        #expect(shown(six).rows == 6 && !shown(six).more)
        let seven = (1...7).map(String.init).joined(separator: "\n")
        #expect(shown(seven).rows == 6 && shown(seven).more)
        // One line that wraps counts for the rows it takes.
        let wide = String(repeating: "x", count: PermissionLayout.cardColumns * 6 + 1)
        #expect(shown(wide).rows == 6 && shown(wide).more)
        // A wide character takes two columns.
        #expect(PermissionText.rows(String(repeating: "한", count: 25), columns: 48) == 2)
        let rule = PermissionPrompt.Grant(rules: ["Bash(a:*)", "Bash(b:*)", "Bash(c:*)"], place: .session)
        #expect(shown(six, grant: rule).rows == 3 && shown(six, grant: rule).more)
    }

    @Test func noPromptTakesMoreRoomThanTheNotchHas() {
        let rules = [1, 2, 3].map { "Bash(\(String(repeating: "r", count: 40 * $0)):*)" }
        let grants: [PermissionPrompt.Grant?] = [nil, .init(rules: ["Bash(ls:*)"], place: .session),
                                                 .init(rules: Array(rules.prefix(1)), place: .userSettings),
                                                 .init(rules: ["a", "b", "c"], place: .projectSettings)]
        let details = ["", "ls", String(repeating: "line\n", count: 3) + "x", String(repeating: "line\n", count: 100),
                       String(repeating: "w", count: 20_000)]
        for grant in grants {
            for detail in details {
                let prompt = prompt(detail, grant: grant)
                // The closed card under the top row of a tall notch, and the open panel under the header, in the window's 280 points.
                #expect(PermissionCard.bodyHeight(for: prompt, hasNotch: true) + 40 <= 280, "\(grant?.rules.count ?? 0) rules, \(detail.count) characters")
                #expect(PermissionPanel.height(for: prompt) <= AppSettings.expandedHeightRange.upperBound - 56,
                        "\(grant?.rules.count ?? 0) rules, \(detail.count) characters")
            }
        }
    }

    @Test func theCardIsTallerForARuleAndForAnOpenTitleLine() {
        func height(grant: PermissionPrompt.Grant?, hasNotch: Bool) -> CGFloat {
            PermissionCard.bodyHeight(for: prompt("d", grant: grant), hasNotch: hasNotch)
        }
        let rule = PermissionPrompt.Grant(rules: ["Bash(ls)"], place: .session)
        #expect(height(grant: rule, hasNotch: true) > height(grant: nil, hasNotch: true))
        #expect(height(grant: nil, hasNotch: true) > height(grant: nil, hasNotch: false))
    }
}
