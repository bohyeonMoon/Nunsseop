import Foundation
import Testing
@testable import Nunsseop

/// The body Claude Code's PreToolUse hook gets for `AskUserQuestion`.
enum QuestionFixtures {
    static func option(_ label: String, _ description: String? = "") -> [String: Any] {
        var option: [String: Any] = ["label": label]
        option["description"] = description
        return option
    }

    static func question(_ text: String = "Which color?", header: String? = "Color", multiSelect: Bool? = false,
                         options: [[String: Any]]? = nil) -> [String: Any] {
        var question: [String: Any] = ["question": text, "options": options ?? [option("Blue", "Calm"), option("Red", "Loud")]]
        question["header"] = header
        question["multiSelect"] = multiSelect
        return question
    }

    static func input(_ questions: [[String: Any]]) -> [String: Any] { ["questions": questions] }

    static func body(tool: String = "AskUserQuestion", event: String = "PreToolUse", input: Any? = nil, cwd: String = "/Users/me/proj") -> Data {
        var json: [String: Any] = ["session_id": "s-1", "cwd": cwd, "permission_mode": "default", "hook_event_name": event, "tool_name": tool]
        json["tool_input"] = input ?? self.input([question()])
        return try! JSONSerialization.data(withJSONObject: json)
    }

    static func parse(_ questions: [[String: Any]], cwd: String = "/Users/me/proj") -> PermissionPrompt.Parsed? {
        PermissionPrompt.parse(body(input: input(questions), cwd: cwd))
    }

    static func text(_ data: Data?) -> String { String(decoding: data ?? Data(), as: UTF8.self) }
}

struct PermissionQuestionParseTests {
    private typealias Q = QuestionFixtures

    @Test func aQuestionBecomesACardWithTheFolderAndEveryAnswer() throws {
        let parsed = try #require(Q.parse([Q.question()], cwd: "/Users/me/my project"))
        let prompt = parsed.prompt
        let asking = try #require(prompt.asking)
        #expect(prompt.title == "Question" && prompt.symbol == "questionmark.bubble" && prompt.folder == "my project")
        #expect(prompt.detail.isEmpty && prompt.grant == nil && prompt.flags.isEmpty && prompt.toolLine.isEmpty)
        #expect(parsed.suggestion == nil)
        #expect(asking.items.count == 1)
        let item = asking.items[0]
        #expect(item.question == "Which color?" && item.header == "Color" && !item.multiSelect && !item.unusual)
        #expect(item.options == [.init(label: "Blue", description: "Calm"), .init(label: "Red", description: "Loud")])
        #expect((parsed.questionInput?["questions"] as? [[String: Any]])?.count == 1)
    }

    @Test func severalQuestionsKeepTheirOrderAndTheirOwnKind() throws {
        let parsed = try #require(Q.parse([
            Q.question("First?", header: nil, multiSelect: nil),
            Q.question("Second?", multiSelect: true, options: [Q.option("A", nil), Q.option("B"), Q.option("C"), Q.option("D")]),
        ]))
        let items = try #require(parsed.prompt.asking?.items)
        #expect(items.map(\.question) == ["First?", "Second?"])
        #expect(items.map(\.multiSelect) == [false, true])
        #expect(items[0].header.isEmpty && items[1].options.map(\.label) == ["A", "B", "C", "D"])
        #expect(items[1].options[0].description.isEmpty)
    }

    @Test func aLimitAtItsEdgeIsStillAQuestion() {
        let options = { (count: Int) in (1...count).map { Q.option("Option \($0)") } }
        #expect(Q.parse((1...4).map { Q.question("Question \($0)?", options: options(4)) }) != nil)
        #expect(Q.parse([Q.question(options: options(2))]) != nil)
        #expect(Q.parse([Q.question(header: String(repeating: "h", count: 80))])?.prompt.asking?.items[0].header.count == PermissionPrompt.headerLimit)
        #expect(Q.parse([Q.question(options: [Q.option(String(repeating: "l", count: PermissionPrompt.labelLimit)), Q.option("b")])]) != nil)
    }

    @Test func whateverIsNotExactlyTheShapeIsLeftToTheTerminal() {
        let options = { (count: Int) in (1...count).map { Q.option("Option \($0)") } }
        let good = Q.question()
        let cases: [(String, [[String: Any]])] = [
            ("no questions", []),
            ("five questions", (1...5).map { Q.question("Question \($0)?") }),
            ("an empty question", [Q.question("")]),
            ("a blank question", [Q.question(" \n\t ")]),
            ("one answer", [Q.question(options: options(1))]),
            ("five answers", [Q.question(options: options(5))]),
            ("an empty label", [Q.question(options: [Q.option("Blue"), Q.option("")])]),
            ("a blank label", [Q.question(options: [Q.option("Blue"), Q.option("  ")])]),
            ("a label that is no text", [Q.question(options: [Q.option("Blue"), ["label": 5]])]),
            ("an answer that is no object", [["question": "q?", "options": [Q.option("Blue"), "Red"]]]),
            ("a description that is no text", [Q.question(options: [Q.option("Blue"), ["label": "Red", "description": 5]])]),
            ("a header that is no text", [["question": "q?", "header": 5, "options": options(2)]]),
            ("a multiSelect that is a string", [["question": "q?", "multiSelect": "true", "options": options(2)]]),
            ("a multiSelect that is a number", [["question": "q?", "multiSelect": 1, "options": options(2)]]),
            ("no answers", [["question": "q?"]]),
            ("answers that are no list", [["question": "q?", "options": "a, b"]]),
            ("no question text", [["options": options(2)]]),
            ("a question asked twice", [Q.question("Same?"), Q.question("Same?")]),
            ("a label offered twice", [Q.question(options: [Q.option("Blue"), Q.option("Blue")])]),
            ("a label too long to show whole", [Q.question(options: [Q.option(String(repeating: "l", count: PermissionPrompt.labelLimit + 1)), Q.option("b")])]),
            ("a question too long to show", [Q.question(String(repeating: "q", count: PermissionPrompt.detailLimit + 1))]),
        ]
        for (name, questions) in cases {
            #expect(Q.parse(questions) == nil, Comment(rawValue: name))
        }
        #expect(Q.parse([good, good]) == nil, "the same question twice")
        for (name, input) in [("no input", nil), ("an input that is no object", "text" as Any), ("no questions key", ["question": "q?"] as Any),
                              ("questions that are no list", ["questions": "q?"] as Any), ("questions that are no objects", ["questions": [1, 2]] as Any)] {
            var json: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/x"]
            json["tool_input"] = input
            #expect(PermissionPrompt.parse(try! JSONSerialization.data(withJSONObject: json)) == nil, Comment(rawValue: name))
        }
    }

    @Test func onlyTheQuestionToolOfAPreToolUseIsTaken() {
        let input = Q.input([Q.question()])
        #expect(PermissionPrompt.parse(Q.body(input: input)) != nil)
        for tool in ["Bash", "ExitPlanMode", "Task", "askuserquestion", ""] {
            #expect(PermissionPrompt.parse(Q.body(tool: tool, input: input)) == nil, "\(tool)")
        }
        #expect(PermissionPrompt.parse(Q.body(tool: "Bash", input: ["command": "ls"])) == nil)
        // As a permission request it is still the terminal's, as is any event nobody knows.
        #expect(PermissionPrompt.parse(Q.body(event: "PermissionRequest", input: input)) == nil)
        #expect(PermissionPrompt.parse(Q.body(event: "PostToolUse", input: input)) == nil)
        #expect(PermissionPrompt.parse(Q.body(event: "", input: input)) == nil)
        var noEvent = (try? JSONSerialization.jsonObject(with: Q.body(input: input))) as! [String: Any]
        noEvent["hook_event_name"] = nil
        #expect(PermissionPrompt.parse(try! JSONSerialization.data(withJSONObject: noEvent)) == nil)
        var noTool = (try? JSONSerialization.jsonObject(with: Q.body(input: input))) as! [String: Any]
        noTool["tool_name"] = nil
        #expect(PermissionPrompt.parse(try! JSONSerialization.data(withJSONObject: noTool)) == nil)
    }

    @Test func approvalsAreUnchangedAndHaveNoQuestions() throws {
        let parsed = try #require(PermissionPrompt.parse(PermissionTestServer.hookInput()))
        #expect(parsed.prompt.asking == nil && parsed.questionInput == nil)
    }

    // MARK: What is shown is escaped, what is sent back is not

    @Test func textThatCouldMisleadIsWrittenOutOnTheCardButKeptAsItWasForTheAnswer() throws {
        let sneaky = "Blue\u{202E}eulB"
        let parsed = try #require(Q.parse([Q.question("Pick\u{202E}it", header: "H\u{200B}", options: [Q.option(sneaky, "d\u{202E}"), Q.option("Red")])]))
        let item = try #require(parsed.prompt.asking?.items.first)
        #expect(item.question == "Pick⟨U+202E⟩it" && item.header == "H⟨U+200B⟩")
        #expect(item.options[0].label == "Blue⟨U+202E⟩eulB" && item.options[0].description == "d⟨U+202E⟩")
        let label = ((parsed.questionInput?["questions"] as? [[String: Any]])?[0]["options"] as? [[String: Any]])?[0]["label"] as? String
        #expect(label == sneaky)
    }

    @Test func lineBreaksOfAQuestionAndItsDescriptionStayAndThoseOfALabelAreWrittenOut() throws {
        let item = try #require(Q.parse([Q.question("a\nb", options: [Q.option("x\ny", "c\nd"), Q.option("z")])])?.prompt.asking?.items.first)
        #expect(item.question == "a\nb" && item.options[0].description == "c\nd")
        #expect(item.options[0].label == "x⟨U+000A⟩y")
    }

    @Test func aScalarThatCanPassForASCIIAnywhereRaisesTheChipAndPlainTextDoesNot() throws {
        func unusual(_ question: [String: Any]) throws -> Bool { try #require(Q.parse([question])?.prompt.asking?.items.first).unusual }
        #expect(try !unusual(Q.question()))
        #expect(try !unusual(Q.question("어느 색이 좋아요?", header: "색", options: [Q.option("파랑", "차분한"), Q.option("빨강")])))
        #expect(try unusual(Q.question("Which café?")))
        #expect(try unusual(Q.question(header: "Café")))
        #expect(try unusual(Q.question(options: [Q.option("Café"), Q.option("Red")])))
        #expect(try unusual(Q.question(options: [Q.option("Blue", "A café"), Q.option("Red")])))
        #expect(try unusual(Q.question("привет мир")))
    }

    @Test func aLongDescriptionIsClippedBeforeItIsEscapedAndALongHeaderToo() throws {
        let long = String(repeating: "d", count: 500)
        let item = try #require(Q.parse([Q.question(header: String(repeating: "h", count: 60), options: [Q.option("a", long), Q.option("b")])])?.prompt.asking?.items.first)
        #expect(item.options[0].description == String(repeating: "d", count: PermissionPrompt.optionDescriptionLimit - 1) + "…")
        #expect(item.header == String(repeating: "h", count: PermissionPrompt.headerLimit - 1) + "…")
        // Cut before it is escaped, an escape is never cut in two.
        let marks = String(repeating: "\u{202E}", count: 300)
        let escaped = try #require(Q.parse([Q.question(options: [Q.option("a", marks), Q.option("b")])])?.prompt.asking?.items.first).options[0].description
        #expect(escaped.hasSuffix("…") && escaped.components(separatedBy: "⟨").count == escaped.components(separatedBy: "⟩").count)
    }

    @Test func theDemoIsAQuestionOfTwoSteps() throws {
        let asking = try #require(PermissionPrompt.demoQuestion.asking)
        #expect(asking.items.map(\.multiSelect) == [false, true])
    }

    // MARK: Questions that could blur what the user picked, or that cannot be answered

    @Test func twoAnswersOrQuestionsThatOnlyDifferInWhitespaceAreLeftToTheTerminal() {
        let cases: [(String, [[String: Any]])] = [
            ("a trailing space", [Q.question(options: [Q.option("Yes", "Go"), Q.option("Yes ", "Go")])]),
            ("a leading space", [Q.question(options: [Q.option("Yes"), Q.option(" Yes")])]),
            ("a doubled inner space", [Q.question(options: [Q.option("Yes it is"), Q.option("Yes  it is")])]),
            ("a tab for a space", [Q.question(options: [Q.option("Yes it is"), Q.option("Yes\tit is")])]),
            ("a label with a space around it, alone", [Q.question(options: [Q.option("Yes "), Q.option("No")])]),
            ("questions that differ in whitespace", [Q.question("Proceed?"), Q.question("Proceed? ")]),
            ("questions that differ in inner whitespace", [Q.question("Do  it?"), Q.question("Do it?")]),
        ]
        for (name, questions) in cases {
            #expect(Q.parse(questions) == nil, Comment(rawValue: name))
        }
        #expect(Q.parse([Q.question(options: [Q.option("Yes it is"), Q.option("No it is not")])]) != nil)
    }

    @Test func aMultiSelectLabelWithACommaAndASpaceIsLeftToTheTerminal() {
        let options = [Q.option("A"), Q.option("B"), Q.option("A, B")]
        #expect(Q.parse([Q.question("Which?", multiSelect: true, options: options)]) == nil)
        #expect(Q.parse([Q.question("Which?", multiSelect: true, options: [Q.option("X"), Q.option("Y, Z")])]) == nil)
        // One answer only, the join never happens.
        #expect(Q.parse([Q.question("Which?", multiSelect: false, options: options)]) != nil)
        // A comma without the space joins nothing that reads like two answers.
        #expect(Q.parse([Q.question("Which?", multiSelect: true, options: [Q.option("A"), Q.option("B,C")])]) != nil)
    }

    @Test func anInputThatCouldNotBeWrittenBackIsLeftToTheTerminal() throws {
        func body(extra: String) -> Data {
            Data(("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"AskUserQuestion\",\"cwd\":\"/x\",\"tool_input\":{\"questions\":[{\"question\":\"Q?\","
                  + "\"header\":\"h\",\"multiSelect\":false,\"options\":[{\"label\":\"A\"},{\"label\":\"B\"}],\"extra\":\(extra)}]}}").utf8)
        }
        #expect(PermissionPrompt.parse(body(extra: "1")) != nil)
        #expect(PermissionPrompt.parse(body(extra: "-1e999")) == nil)
        #expect(PermissionPrompt.parse(body(extra: "1e999")) == nil)
    }
}

struct PermissionQuestionDecisionTests {
    private typealias Q = QuestionFixtures

    private func decision(_ questions: [[String: Any]], _ picked: [Int: [Int]], extra: [String: Any] = [:]) throws -> String {
        var input = Q.input(questions)
        for (key, value) in extra { input[key] = value }
        return Q.text(PermissionWire.decision(.answered(picked), suggestion: nil, questionInput: input))
    }

    @Test func aSingleAnswerIsExactlyWhatClaudeCodeReads() throws {
        #expect(try decision([Q.question()], [0: [1]]) ==
                #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"answers":{"Which color?":"Red"},"#
                + #""questions":[{"header":"Color","multiSelect":false,"options":[{"description":"Calm","label":"Blue"},"#
                + #"{"description":"Loud","label":"Red"}],"question":"Which color?"}]}}}"#)
    }

    @Test func severalAnswersOfOneQuestionAreJoinedByACommaAndASpaceInTheOrderOfTheOptions() throws {
        let question = Q.question("Which checks?", multiSelect: true, options: [Q.option("Unit"), Q.option("Types"), Q.option("Lint"), Q.option("E2E")])
        let text = try decision([question], [0: [3, 0, 2]])
        #expect(text.contains(#""answers":{"Which checks?":"Unit, Lint, E2E"}"#))
        #expect(try decision([question], [0: [1]]).contains(#""answers":{"Which checks?":"Types"}"#))
    }

    @Test func everyQuestionHasItsAnswerUnderItsOwnText() throws {
        let text = try decision([Q.question("One?"), Q.question("Two?", multiSelect: true)], [0: [0], 1: [0, 1]])
        #expect(text.contains(#""answers":{"One?":"Blue","Two?":"Blue, Red"}"#))
    }

    @Test func theOriginalTextsAreEchoedNotWhatTheCardShows() throws {
        let sneaky = "Re\u{430}d \"quoted\" \u{202E} /path\\x"
        let question = Q.question("C\u{43E}lor? ⟨U+0041⟩", options: [Q.option("Blue"), Q.option(sneaky)])
        let text = try decision([question], [0: [1]])
        let output = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let answers = try #require((((output["hookSpecificOutput"] as? [String: Any])?["updatedInput"]) as? [String: Any])?["answers"] as? [String: String])
        #expect(answers == ["C\u{43E}lor? ⟨U+0041⟩": sneaky])
        // Written as UTF-8, slashes plain, never as the card's escapes.
        #expect(text.contains("Re\u{430}d") && text.contains("/path") && !text.contains("\\/") && !text.contains("⟨U+0430⟩"))
    }

    @Test func theInputComesBackWhole() throws {
        let text = try decision([Q.question()], [0: [0]], extra: ["metadata": ["source": "plan"]])
        #expect(text.contains(#""metadata":{"source":"plan"}"#))
    }

    @Test func anAnswerThatIsNotOneOfTheQuestionsIsNoAnswer() {
        let multi = Q.question("M?", multiSelect: true)
        let single = Q.question("S?")
        let cases: [(String, [[String: Any]], [Int: [Int]])] = [
            ("no answers at all", [single], [:]),
            ("an answer missing", [single, Q.question("T?")], [0: [0]]),
            ("an answer for a question that isn't asked", [single], [0: [0], 1: [0]]),
            ("an answer in the wrong place", [single], [1: [0]]),
            ("no option chosen", [single], [0: []]),
            ("an option that doesn't exist", [single], [0: [2]]),
            ("a negative option", [single], [0: [-1]]),
            ("two options for a question that takes one", [single], [0: [0, 1]]),
            ("an option twice", [multi], [0: [1, 1]]),
            ("an option that doesn't exist among several", [multi], [0: [0, 5]]),
        ]
        for (name, questions, picked) in cases {
            #expect(PermissionWire.decision(.answered(picked), suggestion: nil, questionInput: Q.input(questions)) == nil, Comment(rawValue: name))
        }
        #expect(PermissionWire.decision(.answered([0: [0]]), suggestion: nil, questionInput: ["x": 1]) == nil)
    }

    @Test func anInputWithANumberThatIsNotFiniteIsNoAnswerInsteadOfACrash() {
        let infinite = Q.input([Q.question()]).merging(["extra": -Double.infinity]) { $1 }
        #expect(PermissionWire.decision(.answered([0: [0]]), suggestion: nil, questionInput: infinite) == nil)
        let nan = Q.input([Q.question()]).merging(["extra": Double.nan]) { $1 }
        #expect(PermissionWire.decision(.answered([0: [0]]), suggestion: nil, questionInput: nan) == nil)
    }

    @Test func aQuestionTakesNoApprovalAndAnApprovalNoAnswer() {
        let input = Q.input([Q.question()])
        for answer in [PermissionAnswer.allow, .deny, .always, .terminal] {
            #expect(PermissionWire.decision(answer, suggestion: PermissionTestServer.addRules, questionInput: input) == nil, "\(answer)")
        }
        #expect(PermissionWire.decision(.answered([0: [0]]), suggestion: nil) == nil)
        #expect(PermissionWire.decision(.terminal, suggestion: nil) == nil)
    }
}

struct QuestionDraftTests {
    private typealias Q = QuestionFixtures

    private func asking(_ questions: [[String: Any]]) throws -> Asking {
        try #require(Q.parse(questions)?.prompt.asking)
    }

    @Test func aQuestionThatTakesOneAnswerIsAnsweredByPickingIt() throws {
        let asking = try asking([Q.question()])
        var draft = QuestionDraft()
        #expect(draft.apply(.pick(1), to: asking) == .finished([0: [1]]))
    }

    @Test func severalQuestionsAreAskedOneAfterTheOtherAndTheLastSends() throws {
        let asking = try asking([Q.question("A?"), Q.question("B?"), Q.question("C?")])
        var draft = QuestionDraft()
        #expect(draft.apply(.pick(0), to: asking) == .next && draft.step == 1)
        #expect(draft.apply(.pick(1), to: asking) == .next && draft.step == 2)
        #expect(draft.apply(.pick(0), to: asking) == .finished([0: [0], 1: [1], 2: [0]]))
    }

    @Test func aQuestionThatTakesSeveralIsToggledAndSentOnlyWithOneChosen() throws {
        let asking = try asking([Q.question(multiSelect: true, options: [Q.option("A"), Q.option("B"), Q.option("C")]), Q.question("Next?")])
        var draft = QuestionDraft()
        #expect(draft.apply(.submit, to: asking) == .stay && draft.step == 0)
        #expect(draft.apply(.toggle(2), to: asking) == .stay && draft.chosen == [2])
        #expect(draft.apply(.toggle(0), to: asking) == .stay && draft.chosen == [0, 2])
        #expect(draft.apply(.toggle(2), to: asking) == .stay && draft.chosen == [0])
        #expect(draft.apply(.toggle(0), to: asking) == .stay && draft.chosen.isEmpty)
        #expect(draft.apply(.submit, to: asking) == .stay)
        _ = draft.apply(.toggle(2), to: asking)
        _ = draft.apply(.toggle(1), to: asking)
        #expect(draft.apply(.submit, to: asking) == .next && draft.step == 1 && draft.chosen.isEmpty)
        #expect(draft.apply(.pick(0), to: asking) == .finished([0: [1, 2], 1: [0]]))
    }

    @Test func picksAndTogglesOfTheOtherKindAndOfOptionsThatDontExistDoNothing() throws {
        let multi = try asking([Q.question(multiSelect: true)])
        let single = try asking([Q.question()])
        var draft = QuestionDraft()
        #expect(draft.apply(.pick(0), to: multi) == .stay && draft.answers.isEmpty)
        #expect(draft.apply(.toggle(0), to: single) == .stay && draft.chosen.isEmpty)
        #expect(draft.apply(.submit, to: single) == .stay)
        #expect(draft.apply(.pick(2), to: single) == .stay && draft.apply(.pick(-1), to: single) == .stay)
        #expect(draft.apply(.toggle(9), to: multi) == .stay && draft.chosen.isEmpty)
    }

    @Test func theTerminalCanBeAskedAtAnyStep() throws {
        let asking = try asking([Q.question("A?"), Q.question("B?")])
        var draft = QuestionDraft()
        #expect(draft.apply(.terminal, to: asking) == .terminal)
        _ = draft.apply(.pick(0), to: asking)
        #expect(draft.apply(.terminal, to: asking) == .terminal)
    }
}

@MainActor
struct QuestionBoardTests {
    private typealias Q = QuestionFixtures

    private final class Clock { var now: TimeInterval = 1_000 }

    private func board(_ clock: Clock) -> PermissionBoard {
        PermissionBoard(gate: PermissionClickGate(clock: { clock.now }))
    }

    private func question(_ questions: [[String: Any]] = [Q.question()]) throws -> PermissionPrompt {
        try #require(Q.parse(questions)?.prompt)
    }

    private func approval(_ detail: String = "ls") -> PermissionPrompt {
        PermissionPrompt(id: UUID(), title: "Run a command", symbol: "terminal", detail: detail, folder: "proj", grant: nil)
    }

    /// Lets the card's delay pass and a press begin and end on it, as a real click does.
    private func click(_ board: PermissionBoard, _ clock: Clock, _ prompt: PermissionPrompt, _ action: QuestionAction) {
        clock.now += PermissionClickGate.delay + 0.1
        board.gate.pressBegan()
        clock.now += 0.05
        board.act(prompt, action)
    }

    @Test func aClickJustAfterTheCardAppearsAnswersNothing() throws {
        let clock = Clock(), board = board(clock)
        var answers: [PermissionAnswer] = []
        board.onAnswer = { answers.append($1) }
        let prompt = try question()
        board.add(prompt)
        board.gate.pressBegan()
        board.act(prompt, .pick(0))
        board.act(prompt, .terminal)
        clock.now += PermissionClickGate.delay - 0.01
        board.act(prompt, .pick(0))
        #expect(answers.isEmpty && board.current == prompt && board.draft(for: prompt) == QuestionDraft())
    }

    @Test func theAnswerGoesToTheServerAndTheCardLeaves() throws {
        let clock = Clock(), board = board(clock)
        var answers: [(UUID, PermissionAnswer)] = []
        board.onAnswer = { answers.append(($0, $1)) }
        let prompt = try question()
        board.add(prompt)
        click(board, clock, prompt, .pick(1))
        #expect(answers.count == 1 && answers[0].0 == prompt.id && answers[0].1 == .answered([0: [1]]))
        #expect(board.current == nil && board.drafts.isEmpty)
    }

    @Test func movingOnClosesTheGateAgainSoTheSameSpotCannotAnswerTheNextQuestionUnseen() throws {
        let clock = Clock(), board = board(clock)
        var answers: [PermissionAnswer] = []
        board.onAnswer = { answers.append($1) }
        let prompt = try question([Q.question("A?"), Q.question("B?")])
        board.add(prompt)
        click(board, clock, prompt, .pick(0))
        #expect(board.draft(for: prompt).step == 1 && answers.isEmpty && !board.gate.isReady)
        // A second click on the same spot, a moment later.
        clock.now += 0.2
        board.gate.pressBegan()
        board.act(prompt, .pick(0))
        #expect(board.draft(for: prompt).step == 1 && answers.isEmpty)
        click(board, clock, prompt, .pick(1))
        #expect(answers == [.answered([0: [0], 1: [1]])])
    }

    @Test func aQuestionThatTakesSeveralIsToggledByClicksThatCount() throws {
        let clock = Clock(), board = board(clock)
        var answers: [PermissionAnswer] = []
        board.onAnswer = { answers.append($1) }
        let prompt = try question([Q.question(multiSelect: true, options: [Q.option("A"), Q.option("B"), Q.option("C")])])
        board.add(prompt)
        board.gate.pressBegan()
        board.act(prompt, .toggle(0))
        #expect(board.draft(for: prompt).chosen.isEmpty, "too soon")
        click(board, clock, prompt, .toggle(2))
        click(board, clock, prompt, .toggle(0))
        #expect(board.draft(for: prompt).chosen == [0, 2])
        click(board, clock, prompt, .submit)
        #expect(answers == [.answered([0: [0, 2]])])
    }

    @Test func answeringInTheTerminalLetsTheHookGo() throws {
        let clock = Clock(), board = board(clock)
        var answers: [PermissionAnswer] = []
        board.onAnswer = { answers.append($1) }
        let prompt = try question([Q.question("A?"), Q.question("B?")])
        board.add(prompt)
        click(board, clock, prompt, .pick(0))
        click(board, clock, prompt, .terminal)
        #expect(answers == [.terminal] && board.current == nil && board.drafts.isEmpty)
    }

    @Test func questionsAndApprovalsShareOneQueueInOrder() throws {
        let clock = Clock(), board = board(clock)
        var answers: [(UUID, PermissionAnswer)] = []
        board.onAnswer = { answers.append(($0, $1)) }
        let first = approval("one"), asked = try question([Q.question("A?"), Q.question("B?")]), last = approval("three")
        for prompt in [first, asked, last] { board.add(prompt) }
        #expect(board.prompts == [first, asked, last])

        // The question is not in front: a click aimed at it does nothing.
        clock.now += 1
        board.act(asked, .pick(0))
        #expect(board.draft(for: asked) == QuestionDraft() && answers.isEmpty)
        // And an approval takes no question's click.
        board.act(first, .pick(0))
        board.act(first, .terminal)
        #expect(answers.isEmpty && board.current == first)

        board.answer(first, .allow)
        #expect(board.current == asked && !board.gate.isReady, "the question gets the delay as any card does")
        click(board, clock, asked, .pick(0))
        click(board, clock, asked, .pick(0))
        #expect(answers.map(\.1) == [.allow, .answered([0: [0], 1: [0]])])
        #expect(board.current == last && board.drafts.isEmpty)
        board.answer(last, .deny)
        #expect(answers.map(\.1).last == .deny && board.current == nil)
    }

    @Test func aHookThatIsGoneTakesItsQuestionAndItsProgressAway() throws {
        let clock = Clock(), board = board(clock)
        var answers = 0
        board.onAnswer = { _, _ in answers += 1 }
        let asked = try question([Q.question("A?"), Q.question("B?")]), next = approval()
        board.add(asked)
        board.add(next)
        click(board, clock, asked, .pick(0))
        #expect(board.draft(for: asked).step == 1)
        board.remove(asked.id)
        #expect(board.prompts == [next] && board.drafts.isEmpty)
        click(board, clock, asked, .pick(0))
        #expect(answers == 0 && board.current == next)
        board.add(try question())
        board.clear()
        #expect(board.current == nil && board.drafts.isEmpty)
    }

    @Test func eachQuestionKeepsItsOwnProgress() throws {
        let clock = Clock(), board = board(clock)
        board.onAnswer = { _, _ in }
        let first = try question([Q.question("A?"), Q.question("B?")]), second = try question([Q.question("C?"), Q.question("D?")])
        board.add(first)
        board.add(second)
        click(board, clock, first, .pick(1))
        #expect(board.draft(for: first).step == 1 && board.draft(for: second) == QuestionDraft())
    }
}
