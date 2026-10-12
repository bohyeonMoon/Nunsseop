import Foundation
import Testing
@testable import Nunsseop

/// Records the plans a sender is asked to run, and where it ran them.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [[AgentStep]] = []
    private var threads: [Bool] = []
    var passes = true

    var recorded: [[AgentStep]] { lock.withLock { plans } }
    var ranOnMainThread: [Bool] { lock.withLock { threads } }

    var sender: AgentSender {
        AgentSender { [self] steps in
            lock.withLock {
                plans.append(steps)
                threads.append(Thread.isMainThread)
            }
            return passes
        }
    }
}

struct AgentInputHeaderTests {
    @Test func aMuxySessionIsUpToTwentyAsciiDigits() {
        #expect(AgentInput.muxySession("1978299613479001934") == "1978299613479001934")
        #expect(AgentInput.muxySession("7") == "7")
        #expect(AgentInput.muxySession(String(repeating: "9", count: 20)) != nil)
        for bad in [nil, "", String(repeating: "9", count: 21), "12a", " 12", "12 ", "12\n", "-1", "1.5", "١٢٣", "1;touch x", "$(id)"] {
            #expect(AgentInput.muxySession(bad) == nil, "\(bad ?? "nil")")
        }
    }

    @Test func aCmuxSurfaceIsAUUIDsCharactersWithinALengthCap() {
        #expect(AgentInput.cmuxSurface("6F1B2C3D-0000-4000-8000-000000000001") == "6F1B2C3D-0000-4000-8000-000000000001")
        #expect(AgentInput.cmuxSurface("6f1b2c3d") == "6f1b2c3d")
        #expect(AgentInput.cmuxSurface(String(repeating: "a", count: 64)) != nil)
        let bad: [String?] = [nil, "", "6f1b2c3", String(repeating: "a", count: 65), "-6f1b2c3d-0000", "6f1b2c3g-0000", "6f1b2c3d-0000\n",
                              "6f1b2c3d 0000", "surface:2", "6f1b2c3d;id", "$(id)abcdef"]
        for value in bad { #expect(AgentInput.cmuxSurface(value) == nil, "\(value ?? "nil")") }
    }

    @Test func theHookEventCarriesTheTerminalsInputTarget() {
        let base = ["x-session": "s", "x-event": "Stop"]
        #expect(AgentHook.event(headers: base)?.input == nil)
        #expect(AgentHook.event(headers: base.merging(["x-muxy": "42"]) { $1 })?.input == .muxy("42"))
        #expect(AgentHook.event(headers: base.merging(["x-cmux": "6F1B2C3D-0000"]) { $1 })?.input == .cmux("6F1B2C3D-0000"))
        // A Muxy session started in a cmux terminal has both variables: the Muxy one is the nearer terminal.
        #expect(AgentHook.event(headers: base.merging(["x-muxy": "42", "x-cmux": "6F1B2C3D-0000"]) { $1 })?.input == .muxy("42"))
        // A bad id of one falls to the other, and a bad one alone only leaves the session without a target.
        #expect(AgentHook.event(headers: base.merging(["x-muxy": "4 2", "x-cmux": "6F1B2C3D-0000"]) { $1 })?.input == .cmux("6F1B2C3D-0000"))
        let junk = AgentHook.event(headers: base.merging(["x-muxy": "4\n2", "x-cmux": "../x"]) { $1 })
        #expect(junk != nil && junk?.input == nil)
        // The same for Codex's.
        #expect(AgentHook.event(headers: base.merging(["x-muxy": "42", "x-agent": "codex"]) { $1 })?.input == .muxy("42"))
    }

    @Test func aSessionInTmuxZellijOrScreenHasNoTargetFromTheHook() {
        let headers = ["x-session": "s", "x-event": "Stop", "x-muxy": "42", "x-cmux": "6F1B2C3D-0000"]
        // The ids are those of the terminal around the multiplexer, and typing reaches its active pane, not the session's.
        for value in ["1", "11", "111"] {
            let event = AgentHook.event(headers: headers.merging(["x-mux": value]) { $1 })
            #expect(event != nil && event?.input == nil, Comment(rawValue: value))
            #expect(AgentHook.event(headers: headers.merging(["x-mux": value, "x-agent": "codex"]) { $1 })?.input == nil)
        }
        #expect(AgentHook.event(headers: headers.merging(["x-mux": ""]) { $1 })?.input == .muxy("42"))
    }

    @Test func aSessionInAHerdrPaneOrInTheBackgroundHasNoTargetFromTheHook() {
        let headers = ["x-session": "s", "x-event": "Stop", "x-muxy": "42", "x-cmux": "6F1B2C3D-0000"]
        // The variables are those of the terminal around herdr, or of the daemon: typing there would miss the session.
        #expect(AgentHook.event(headers: headers.merging(["x-herdr": "1"]) { $1 })?.input == nil)
        #expect(AgentHook.event(headers: headers.merging(["x-background": "1"]) { $1 })?.input == nil)
    }
}

@MainActor
struct AgentHooksInputTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func make() -> (hooks: AgentHooks, board: AgentBoard) {
        let board = AgentBoard()
        return (AgentHooks(board: board, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }), board)
    }

    private func input(_ board: AgentBoard, _ id: String = "a") -> AgentInput? {
        board.entries(now: start).first { $0.id == id }?.agent.input
    }

    @Test func theTargetReachesTheBoardAndIsTheOneOfTheLatestEvent() {
        let (hooks, board) = make()
        hooks.apply(AgentEvent(session: "a", action: .working, input: .muxy("42")), now: start)
        #expect(input(board) == .muxy("42"))
        hooks.apply(AgentEvent(session: "a", action: .working, input: .muxy("42")), now: start)
        hooks.apply(AgentEvent(session: "a", action: .opened, input: .muxy("42")), now: start)
        #expect(input(board) == .muxy("42"))
        // A session moved to another terminal (resumed there) takes the new one.
        hooks.apply(AgentEvent(session: "a", action: .working, input: .cmux("6F1B2C3D-0000")), now: start)
        #expect(input(board) == .cmux("6F1B2C3D-0000"))
        hooks.apply(AgentEvent(session: "a", action: .finished, app: "com.x", input: .cmux("6F1B2C3D-0000")), now: start)
        hooks.activated("com.x")
        #expect(input(board) == .cmux("6F1B2C3D-0000"))
    }

    @Test func aSessionResumedInATerminalWithoutAnInputAPILosesTheOldTarget() {
        for action in [AgentAction.working, .needsInput, .opened, .idle, .finished] {
            let (hooks, board) = make()
            hooks.apply(AgentEvent(session: "a", action: .working, app: "com.muxy", input: .muxy("42")), now: start)
            #expect(input(board) == .muxy("42"))
            hooks.apply(AgentEvent(session: "a", action: action, app: "com.mitchellh.ghostty"), now: start)
            #expect(input(board) == nil, Comment(rawValue: "\(action)"))
        }
    }

    @Test func aSessionOpenedWithoutOneStillGetsTheTargetOfItsNextEvent() {
        let (hooks, board) = make()
        hooks.apply(AgentEvent(session: "a", action: .opened), now: start)
        #expect(input(board) == nil)
        hooks.apply(AgentEvent(session: "a", action: .opened, input: .muxy("7")), now: start)
        #expect(input(board) == .muxy("7"))
    }

    @Test func herdrAgentsGetThePaneOnTheirSocketAndNothingWithoutOne() {
        let panes = ["w1:p1": Herdr.PaneState(status: "working", since: start, agent: "claude")]
        #expect(Herdr.boardAgents(panes, socket: "/tmp/herdr.sock")["w1:p1"]?.input == .herdr(pane: "w1:p1", socket: "/tmp/herdr.sock"))
        #expect(Herdr.boardAgents(panes)["w1:p1"]?.input == nil)
    }
}

struct AgentSendTextTests {
    @Test func controlCharactersBecomeSpacesAndTheEndsAreTrimmed() {
        #expect(AgentSend.message("  hello\r\nworld\tagain  ") == "hello  world again")
        #expect(AgentSend.message("a\u{1B}[31mb") == "a [31mb")
        #expect(AgentSend.message("a\u{7F}b\u{0}c\u{85}d") == "a b c d")
        #expect(AgentSend.message("a\u{2028}b\u{2029}c") == "a b c")
        #expect(AgentSend.message("한국어 \"quoted\" `tick` $HOME \\n") == "한국어 \"quoted\" `tick` $HOME \\n")
        // Nothing is run or expanded: the text goes through as it is.
        #expect(AgentSend.message("/resume") == "/resume")
    }

    @Test func nothingLeftMeansNothingToSend() {
        for text in ["", "   ", "\n\r\t", "\u{1B}\u{7}", "\u{2028}"] { #expect(AgentSend.message(text) == nil, "\(text.debugDescription)") }
    }

    @Test func aMessageIsCutAtFourThousandCharacters() throws {
        let long = String(repeating: "a", count: 5_000)
        #expect(try #require(AgentSend.message(long)).count == 4_000)
        #expect(AgentSend.message(String(repeating: "a", count: 4_000))?.count == 4_000)
        // The cut leaves no trailing space either.
        let spaced = String(repeating: "a", count: 3_999) + " b"
        #expect(AgentSend.message(spaced) == String(repeating: "a", count: 3_999))
        #expect(try #require(AgentSend.message(String(repeating: "한", count: 4_100))).count == 4_000)
    }

    @Test func plainPathsAreSentAsTheyAre() {
        #expect(AgentSend.quoted(path: "/Users/me/Projects/app/main.swift") == "/Users/me/Projects/app/main.swift")
        #expect(AgentSend.quoted(path: "/Users/me/사진/스크린샷.png") == "/Users/me/사진/스크린샷.png")
        #expect(AgentSend.quoted(path: "/tmp/a_b-c.d+e=f@g%h,i:j") == "/tmp/a_b-c.d+e=f@g%h,i:j")
    }

    @Test func pathsWithSpacesOrShellCharactersAreSingleQuoted() {
        #expect(AgentSend.quoted(path: "/Users/me/My Files/a b.png") == "'/Users/me/My Files/a b.png'")
        #expect(AgentSend.quoted(path: "/tmp/it's here.txt") == #"'/tmp/it'\''s here.txt'"#)
        #expect(AgentSend.quoted(path: "/tmp/a$b") == "'/tmp/a$b'")
        #expect(AgentSend.quoted(path: "/tmp/a;b&c|d") == "'/tmp/a;b&c|d'")
        #expect(AgentSend.quoted(path: "/tmp/(x)") == "'/tmp/(x)'")
        #expect(AgentSend.quoted(path: "/tmp/`x`") == "'/tmp/`x`'")
        #expect(AgentSend.quoted(path: #"/tmp/a\b"#) == #"'/tmp/a\b'"#)
        #expect(AgentSend.quoted(path: "/tmp/*.png") == "'/tmp/*.png'")
        // A screenshot's name holds a narrow no-break space before PM.
        #expect(AgentSend.quoted(path: "/tmp/Screenshot 3.14.15\u{202F}PM.png") == "'/tmp/Screenshot 3.14.15\u{202F}PM.png'")
    }

    @Test func aPathWithAControlCharacterIsRefused() {
        #expect(AgentSend.quoted(path: "/tmp/a\nb") == nil)
        #expect(AgentSend.quoted(path: "/tmp/a\rb") == nil)
        #expect(AgentSend.quoted(path: "/tmp/a\u{1B}b") == nil)
        #expect(AgentSend.quoted(path: "") == nil)
    }

    @Test func droppedFilesAreJoinedWithASpaceAfterTheLast() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b c.png")]
        #expect(AgentSend.paths(urls) == "/tmp/a.png '/tmp/b c.png' ")
        #expect(AgentSend.paths([urls[0]]) == "/tmp/a.png ")
    }

    @Test func onlyFileURLsAreSentAndOneBadPathRefusesTheDrop() throws {
        let web = try #require(URL(string: "https://example.com/a.png"))
        #expect(AgentSend.paths([web]) == nil)
        #expect(AgentSend.paths([]) == nil)
        #expect(AgentSend.paths([web, URL(fileURLWithPath: "/tmp/a.png")]) == "/tmp/a.png ")
        #expect(AgentSend.paths([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b\nc.png")]) == nil)
    }

    @Test func aSessionWaitingOnAPromptTakesNoInputButTheOtherStatesDo() {
        #expect(!AgentSend.accepts(state: .waiting, finished: false))
        #expect(AgentSend.accepts(state: .waiting, finished: true))
        #expect(AgentSend.accepts(state: .idle, finished: false))
        #expect(AgentSend.accepts(state: .working, finished: false))
    }
}

struct AgentSendPlanTests {
    let muxy = URL(fileURLWithPath: "/Applications/Muxy.app/Contents/MacOS/muxy")
    let cmux = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux")
    var clis: TerminalCLIs { TerminalCLIs(muxy: muxy, cmux: cmux) }

    @Test func muxySendsTheTextThenEnterAsArgumentsAfterLookingTheSessionUp() {
        let steps = AgentSend.steps(.muxy("1978299613479001934"), text: "fix the bug", submit: true, clis: clis)
        #expect(steps == [
            .listed(muxy, ["session", "list"], id: "1978299613479001934"),
            .run(muxy, ["session", "send", "1978299613479001934", "fix the bug"]),
            .run(muxy, ["session", "send-keys", "1978299613479001934", "Enter"]),
        ])
    }

    @Test func droppedFilesGoWithoutEnter() {
        let steps = AgentSend.steps(.muxy("42"), text: "/tmp/a.png ", submit: false, clis: clis)
        #expect(steps == [.listed(muxy, ["session", "list"], id: "42"), .run(muxy, ["session", "send", "42", "/tmp/a.png "])])
        #expect(AgentSend.steps(.cmux("6F1B2C3D-0000"), text: "x ", submit: false, clis: clis)?.count == 1)
        #expect(AgentSend.steps(.herdr(pane: "p", socket: "/tmp/h.sock"), text: "x ", submit: false, clis: clis).map { steps in
            if case .socket(_, let requests) = steps[0] { return requests.count } else { return 0 }
        } == 1)
    }

    @Test func aTextStartingWithADashIsSeparatedFromTheOptions() {
        let steps = AgentSend.steps(.muxy("42"), text: "--yes please", submit: false, clis: clis)
        #expect(steps?.last == .run(muxy, ["session", "send", "42", "--", "--yes please"]))
    }

    @Test func cmuxSendsTheTextAsItIsThroughTheMethodAndNotTheEscapingSendCommand() throws {
        let surface = "6F1B2C3D-0000-4000-8000-000000000001"
        let steps = try #require(AgentSend.steps(.cmux(surface), text: #"line\nbreak \t \\ "q" /x"#, submit: true, clis: clis))
        #expect(steps.count == 2)
        guard case .run(let tool, let arguments) = steps[0] else { Issue.record("not a command"); return }
        #expect(tool == cmux && arguments.count == 3 && arguments[0] == "rpc" && arguments[1] == "surface.send_text")
        let params = try #require(try JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: String])
        // The backslashes are the text's own: cmux's `send` would have turned \n into Return.
        #expect(params == ["surface_id": surface, "text": #"line\nbreak \t \\ "q" /x"#])
        #expect(steps[1] == .run(cmux, ["send-key", "--surface", surface, "enter"]))
    }

    @Test func herdrWritesTwoRequestsOnTheSessionsSocket() throws {
        let steps = try #require(AgentSend.steps(.herdr(pane: "w1:p2", socket: "/Users/me/.config/herdr/herdr.sock"), text: "hi \"there\"",
                                                 submit: true, clis: clis))
        guard steps.count == 1, case .socket(let path, let requests) = steps[0] else { Issue.record("not one socket step"); return }
        #expect(path == "/Users/me/.config/herdr/herdr.sock")
        let sent = try requests.map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(sent.map { $0["method"] as? String } == ["pane.send_text", "pane.send_keys"])
        #expect((sent[0]["params"] as? [String: String]) == ["pane_id": "w1:p2", "text": "hi \"there\""])
        let keys = sent[1]["params"] as? [String: Any]
        #expect(keys?["pane_id"] as? String == "w1:p2" && keys?["keys"] as? [String] == ["enter"])
        #expect(requests.allSatisfy { !$0.contains("\n") })
    }

    @Test func aTerminalWhoseToolIsMissingHasNoPlan() {
        let none = TerminalCLIs(muxy: nil, cmux: nil)
        #expect(AgentSend.steps(.muxy("42"), text: "x", submit: true, clis: none) == nil)
        #expect(AgentSend.steps(.cmux("6F1B2C3D-0000"), text: "x", submit: true, clis: none) == nil)
        // herdr is its socket.
        #expect(AgentSend.steps(.herdr(pane: "p", socket: "/tmp/h.sock"), text: "x", submit: true, clis: none) != nil)
    }

    @Test func noPlanGoesThroughAShell() throws {
        let inputs: [AgentInput] = [.muxy("42"), .cmux("6F1B2C3D-0000"), .herdr(pane: "p", socket: "/tmp/h.sock")]
        for input in inputs {
            for step in try #require(AgentSend.steps(input, text: "$(touch pwn); `id` | cat > x", submit: true, clis: clis)) {
                switch step {
                case .run(let tool, let arguments), .listed(let tool, let arguments, _):
                    #expect(!["sh", "bash", "zsh", "dash", "env"].contains(tool.lastPathComponent))
                    #expect(!arguments.contains("-c"))
                case .socket: break
                }
            }
        }
        // The text is one argument of its own, however it looks.
        let steps = try #require(AgentSend.steps(.muxy("42"), text: "a b; c", submit: false, clis: clis))
        #expect(steps.last == .run(muxy, ["session", "send", "42", "a b; c"]))
    }

    @Test func theToolsAreStartedWithoutTheVariablesThatNameANunsseopTerminal() {
        // `muxy session send` types into the terminal of MUXY_SESSION_ID when the id it is given is not a live session.
        #expect(AgentSend.terminalVariables.contains("MUXY_SESSION_ID") && AgentSend.terminalVariables.contains("CMUX_SURFACE_ID"))
    }
}

@MainActor
struct AgentSendModelTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let clis = TerminalCLIs(muxy: URL(fileURLWithPath: "/m/muxy"), cmux: URL(fileURLWithPath: "/c/cmux"))

    private func make(_ recorder: Recorder, agents: [String: AgentBoard.Agent], clis: TerminalCLIs? = nil) -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: agents, now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true },
                                   scratch: [], sender: recorder.sender, clis: { clis ?? self.clis })
        model.fixedRecent = []
        model.refresh(now: start)
        return model
    }

    private func agent(_ state: AgentBoard.State, finished: Bool = false, input: AgentInput? = .muxy("42")) -> AgentBoard.Agent {
        AgentBoard.Agent(state: state, since: start, finished: finished, tool: "claude", input: input)
    }

    private func row(_ model: AgentsTabModel, _ id: String = "a") throws -> AgentRow {
        try #require(model.rows.first { $0.id == "hooks:claude|\(id)" })
    }

    @Test func aRowTakesInputWhenItsTerminalHasAnAPIAndNoPromptWaits() throws {
        let model = make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.idle, input: .muxy("2")),
                                              "c": agent(.waiting, finished: true, input: .muxy("3")),
                                              "d": agent(.waiting, input: .muxy("4")), "e": agent(.working, input: nil)])
        #expect(try row(model, "a").acceptsInput && row(model, "b").acceptsInput && row(model, "c").acceptsInput)
        let blocked = try row(model, "d")
        #expect(!blocked.acceptsInput && blocked.inputBlocked)
        let plain = try row(model, "e")
        #expect(!plain.acceptsInput && !plain.inputBlocked)
    }

    @Test func aMessageIsSentOffTheMainThreadAsTextThenEnter() async throws {
        let recorder = Recorder()
        let model = make(recorder, agents: ["a": agent(.working)])
        #expect(model.send(message: "  run the tests\n", to: try row(model)))
        await eventually { !recorder.recorded.isEmpty }
        #expect(recorder.recorded == [[
            .listed(clis.muxy!, ["session", "list"], id: "42"),
            .run(clis.muxy!, ["session", "send", "42", "run the tests"]),
            .run(clis.muxy!, ["session", "send-keys", "42", "Enter"]),
        ]])
        #expect(recorder.ranOnMainThread == [false])
        #expect(model.notes.isEmpty)
    }

    @Test func droppedFilesAreTypedWithoutEnter() async throws {
        let recorder = Recorder()
        let model = make(recorder, agents: ["a": agent(.idle, input: .cmux("6F1B2C3D-0000"))])
        #expect(model.send(files: [URL(fileURLWithPath: "/tmp/a b.png"), URL(fileURLWithPath: "/tmp/c.txt")], to: try row(model)))
        await eventually { !recorder.recorded.isEmpty }
        let plan = try #require(recorder.recorded.first)
        #expect(plan.count == 1)
        guard case .run(_, let arguments) = plan[0] else { Issue.record("not a command"); return }
        let params = try #require(try JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: String])
        #expect(params["text"] == "'/tmp/a b.png' /tmp/c.txt ")
    }

    @Test func nothingIsSentToASessionWaitingOnAPrompt() async throws {
        let recorder = Recorder()
        let model = make(recorder, agents: ["a": agent(.waiting)])
        let blocked = try row(model)
        #expect(!model.send(message: "yes", to: blocked))
        #expect(!model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: blocked))
        model.compose(blocked)
        #expect(model.composing == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func theSessionIsCheckedAgainAtSendTimeNotAsTheRowWasDrawn() async throws {
        let recorder = Recorder()
        let model = make(recorder, agents: ["a": agent(.working)])
        let drawn = try row(model)
        // The session starts asking for permission after the row was drawn.
        model.refresh(now: start)
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(.waiting)], now: start)
        let later = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: recorder.sender, clis: { clis })
        later.fixedRecent = []
        later.refresh(now: start)
        #expect(!later.send(message: "hello", to: drawn))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func anEmptyMessageOrOneWithoutATargetSendsNothing() async throws {
        let recorder = Recorder()
        let model = make(recorder, agents: ["a": agent(.working), "b": agent(.working, input: nil)])
        #expect(!model.send(message: " \n\t ", to: try row(model)))
        #expect(!model.send(message: "hello", to: try row(model, "b")))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func aFailureLeavesANoteOnTheRowThatGoesAway() async throws {
        let recorder = Recorder()
        recorder.passes = false
        let model = make(recorder, agents: ["a": agent(.working)])
        let target = try row(model)
        #expect(model.send(message: "hello", to: target))
        await eventually { model.notes[target.id] != nil }
        #expect(model.notes[target.id] == String(localized: "Couldn't send. Is the terminal still open?"))
        // A new send clears it.
        recorder.passes = true
        #expect(model.send(message: "again", to: target))
        #expect(model.notes[target.id] == nil)
    }

    @Test func aTerminalWhoseToolIsGoneLeavesANoteAndRunsNothing() async throws {
        let recorder = Recorder()
        let model = make(recorder, agents: ["a": agent(.working)], clis: TerminalCLIs(muxy: nil, cmux: nil))
        let target = try row(model)
        #expect(model.send(message: "hello", to: target))
        #expect(model.notes[target.id] != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func oneMessageFieldIsOpenAtATime() throws {
        let model = make(Recorder(), agents: ["a": agent(.working), "b": agent(.idle)])
        model.compose(try row(model, "a"))
        #expect(model.composing == "hooks:claude|a")
        model.compose(try row(model, "b"))
        #expect(model.composing == "hooks:claude|b")
        model.cancelCompose()
        #expect(model.composing == nil)
    }

    @Test func theFieldClosesWhenItsSessionStartsWaitingOnAPromptOrGoesAway() throws {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(.working)], now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: Recorder().sender, clis: { clis })
        model.fixedRecent = []
        model.refresh(now: start)
        model.compose(try row(model))
        #expect(model.composing != nil)
        board.replace(source: "hooks:claude", with: ["a": agent(.waiting)], now: start)
        model.refresh(now: start)
        #expect(model.composing == nil)
        board.replace(source: "hooks:claude", with: ["a": agent(.working)], now: start)
        model.refresh(now: start)
        model.compose(try row(model))
        board.replace(source: "hooks:claude", with: [:], now: start)
        model.refresh(now: start)
        #expect(model.composing == nil)
    }

    @Test func leavingTheTabClosesTheField() throws {
        let model = make(Recorder(), agents: ["a": agent(.working)])
        model.isShowing = true
        model.compose(try row(model))
        #expect(model.composing != nil)
        model.isShowing = false
        #expect(model.composing == nil)
    }

    @Test func aPromptLeftOpenPastTheActiveWindowStillTakesNoInput() async throws {
        let recorder = Recorder()
        let board = AgentBoard()
        let hooks = AgentHooks(board: board, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil })
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: recorder.sender, clis: { clis })
        model.fixedRecent = []
        hooks.apply(AgentEvent(session: "a", action: .needsInput, input: .muxy("42")), now: start)
        model.refresh(now: start)
        let id = "hooks:claude|a"
        #expect(try #require(model.rows.first { $0.id == id }).state == .waiting)
        #expect(try !#require(model.rows.first { $0.id == id }).acceptsInput)

        // The clock turns the row idle, but nothing closed the dialog.
        let later = start.addingTimeInterval(AgentHooks.activeWindow + 60)
        model.refresh(now: later)
        let row = try #require(model.rows.first { $0.id == id })
        #expect(row.state == .idle && !row.acceptsInput && row.inputBlocked)
        #expect(!model.send(message: "no, stop", to: row))
        #expect(!model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: row))
        model.compose(row)
        #expect(model.composing == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)

        // A hook event that says the dialog is gone does.
        hooks.apply(AgentEvent(session: "a", action: .idle, input: .muxy("42")), now: later)
        model.refresh(now: later)
        #expect(try #require(model.rows.first { $0.id == id }).acceptsInput)
        hooks.apply(AgentEvent(session: "a", action: .needsInput, input: .muxy("42")), now: later)
        hooks.apply(AgentEvent(session: "a", action: .working, input: .muxy("42")), now: later)
        model.refresh(now: later)
        #expect(try #require(model.rows.first { $0.id == id }).acceptsInput)
    }

    @Test func aFinishedTurnPastItsWindowStillTakesInput() throws {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": AgentBoard.Agent(state: .waiting, since: start, finished: true, tool: "claude",
                                                                      idleFrom: start.addingTimeInterval(600), input: .muxy("42"))], now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: Recorder().sender, clis: { clis })
        model.fixedRecent = []
        model.refresh(now: start.addingTimeInterval(700))
        #expect(try row(model).state == .idle && row(model).acceptsInput)
    }

    @Test func nothingIsSentToATerminalWhereAnotherSessionMayHaveAPromptOpen() async throws {
        let recorder = Recorder()
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["parent": agent(.waiting), "child": agent(.working), "other": agent(.working, input: .muxy("7"))],
                      now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: recorder.sender, clis: { clis })
        model.fixedRecent = []
        model.refresh(now: start)
        let child = try row(model, "child")
        #expect(!child.acceptsInput && child.inputBlocked)
        #expect(!model.send(message: "yes", to: child))
        #expect(!model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: child))
        model.compose(child)
        #expect(model.composing == nil)
        // A session of another terminal is not held back.
        #expect(try row(model, "other").acceptsInput)
        #expect(model.send(message: "hello", to: try row(model, "other")))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.count == 1)
        #expect(recorder.recorded.first?.contains(.run(URL(fileURLWithPath: "/m/muxy"), ["session", "send", "7", "hello"])) == true)
    }

    @Test func aPromptOpenInASharedTerminalPastTheWindowClosesTheSiblingsField() throws {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["parent": agent(.working), "child": agent(.working)], now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: Recorder().sender, clis: { clis })
        model.fixedRecent = []
        model.refresh(now: start)
        model.compose(try row(model, "child"))
        #expect(model.composing != nil)
        board.replace(source: "hooks:claude", with: ["parent": agent(.waiting), "child": agent(.working)], now: start)
        model.refresh(now: start)
        #expect(model.composing == nil)
    }

    @Test func aFieldIsClosedByItsOwnRowOnlyWhenItsViewGoesAway() throws {
        let model = make(Recorder(), agents: ["a": agent(.working), "b": agent(.working)])
        model.compose(try row(model, "a"))
        // Another row's field going away (the one just replaced) leaves this one open.
        model.cancelCompose(row: "hooks:claude|b")
        #expect(model.composing == "hooks:claude|a")
        model.cancelCompose(row: "hooks:claude|a")
        #expect(model.composing == nil)
    }

    @Test func holdingAFileOverATabOpensItAfterTheDelayUnlessItLeaves() {
        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        let hover = TabDragHover { scheduled.append(($0, $1)) }
        var opened = 0
        hover.entered { opened += 1 }
        #expect(scheduled.count == 1 && scheduled[0].0 == TabDragHover.delay)
        scheduled[0].1.perform()
        #expect(opened == 1)

        hover.entered { opened += 1 }
        hover.exited()
        scheduled[1].1.perform()
        #expect(opened == 1)

        // Entering again replaces the pending switch rather than adding a second.
        hover.entered { opened += 10 }
        hover.entered { opened += 100 }
        scheduled[2].1.perform()
        scheduled[3].1.perform()
        #expect(opened == 101)
    }

    @Test func theAgentsTabTakesDropsOnItsRowsNotTheNotch() {
        #expect(NotchDropDelegate.agentsTabTakesDrops(expanded: true, tab: .agents))
        #expect(!NotchDropDelegate.agentsTabTakesDrops(expanded: true, tab: .shelf))
        #expect(!NotchDropDelegate.agentsTabTakesDrops(expanded: false, tab: .agents))
    }
}

/// What launch does to the agent hooks of a version without the terminal headers: the command is replaced inside the same hook, so
/// no group moves (Codex keys its trust of a hook by the position of its group).
struct AgentHookMigrationTests {
    private func old(_ command: String) -> String {
        command.replacingOccurrences(of: #"-H "X-Muxy: ${MUXY_SESSION_ID}" -H "X-Cmux: ${CMUX_SURFACE_ID}" -H "X-Mux: ${TMUX:+1}${ZELLIJ:+1}${STY:+1}" "#, with: "")
    }

    private func group(_ command: String) -> [String: Any] {
        ["matcher": "", "hooks": [["type": "command", "command": command, "timeout": 10] as [String: Any]]]
    }

    /// A hook of ours as Nunsseop writes it: no matcher and no timeout.
    private func ours(_ command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command] as [String: Any]]]
    }

    private func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        groups(settings, event).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test func theOldCommandsDifferFromTheNewOnesByTheTerminalHeadersOnly() {
        for agent in [AgentKind.claude, .codex] {
            let current = NotifyServer.agentHookCommand(for: agent)
            #expect(old(current) != current && current.contains("X-Muxy") && current.contains("X-Cmux") && current.contains("X-Mux:") && !old(current).contains("X-Muxy"))
        }
    }

    @Test func codexHooksKeepTheirGroupsAndOrderWhileTheCommandChangesInPlace() throws {
        try withTempHome { home in
            let hooksURL = NotifyIntegration.codex.hooksURL
            try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(CodexNotify.adding(to: "model = \"o3\"\n").utf8).write(to: NotifyIntegration.codex.configURL)
            let agent = old(NotifyServer.agentHookCommand(for: .codex))
            let muxy = "muxy-codex-hook.sh stop # muxy-notification-hook", gk = "gk ai hook run --host codex"
            let before: [String: Any] = ["hooks": [
                "UserPromptSubmit": [ours(agent)],
                "PermissionRequest": [group(gk), ours(agent)],
                "Stop": [group(muxy), ours(agent), group(gk)],
                "Interrupt": [ours(agent)],
                "SessionEnd": [ours(agent), group(gk)],
            ]]
            try NotifyIntegration.writeJSON(before, to: hooksURL)
            try NotifyIntegration.$permissionPromptsOverride.withValue(false) { NotifyIntegration.updateConnectedNow() }

            let after = try NotifyIntegration.loadJSON(at: hooksURL)
            let current = NotifyServer.agentHookCommand(for: .codex)
            for event in ["UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"] {
                // Same groups at the same positions; the agent command is the only thing that differs.
                let expected = commands(before, event).map { $0 == agent ? current : $0 }
                #expect(commands(after, event) == expected, "\(event)")
                #expect(groups(after, event).count == groups(before, event).count, "\(event)")
            }
            #expect(groups(after, "Stop")[0] as NSDictionary == groups(before, "Stop")[0] as NSDictionary)
            #expect(groups(after, "Stop")[2] as NSDictionary == groups(before, "Stop")[2] as NSDictionary)
            #expect(NotifyIntegration.$permissionPromptsOverride.withValue(false) { JSONHook.isCurrent(NotifyIntegration.codex.hooks, in: after) })

            // Done once: another launch leaves the file alone.
            let written = try Data(contentsOf: hooksURL)
            try NotifyIntegration.$permissionPromptsOverride.withValue(false) { NotifyIntegration.updateConnectedNow() }
            #expect(try Data(contentsOf: hooksURL) == written)
        }
    }

    @Test func claudeCodesHooksKeepTheirOrderAroundTheUsersOwn() throws {
        try withTempHome { _ in
            let claude = NotifyIntegration.claudeCode
            let agent = old(NotifyServer.agentHookCommand)
            let mine: [String: Any] = ["hooks": [["type": "command", "command": "mine.sh"]]]
            var before: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": agent]]], mine],
                                                   "SessionStart": [mine, ["hooks": [["type": "command", "command": agent]]]]]]
            before = try JSONHook.adding([("Notification", NotifyServer.hookCommand(title: "Claude Code")),
                                          ("Notification", agent), ("UserPromptSubmit", agent), ("StopFailure", agent), ("SessionEnd", agent)],
                                         to: before)
            try NotifyIntegration.writeJSON(before, to: claude.configURL)
            try NotifyIntegration.$permissionPromptsOverride.withValue(false) { NotifyIntegration.updateConnectedNow() }
            let after = try NotifyIntegration.loadJSON(at: claude.configURL)
            #expect(commands(after, "Stop") == [NotifyServer.agentHookCommand, "mine.sh"])
            #expect(commands(after, "SessionStart") == ["mine.sh", NotifyServer.agentHookCommand])
            #expect(NotifyIntegration.$permissionPromptsOverride.withValue(false) { JSONHook.isCurrent(claude.hooks, in: after) })
        }
    }

    @Test func aHookThatChangedInMoreThanItsCommandStillRewritesTheWholeSet() throws {
        let agent = NotifyServer.agentHookCommand(for: .codex)
        let table: JSONHook.Table = [("Stop", agent), ("Interrupt", agent)]
        // An agent hook under an event the table doesn't have (and no hook to take its place) is dropped, not left behind.
        let start = try JSONHook.adding([("Stop", old(agent)), ("SessionStart", old(agent))], to: [:])
        let fixed = try #require(try JSONHook.updating(table, in: start))
        #expect(JSONHook.isCurrent(table, in: fixed))
        #expect(commands(fixed, "SessionStart").isEmpty)
    }
}

/// The steps run for real, against stand-ins: a script that records what it was given, and a socket server in Python.
struct AgentSendExecutionTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-send-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stub(_ body: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("tool")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func aCommandGetsEachArgumentAsItIsAndNoneOfNunsseopsTerminalVariables() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = try stub(#"for a; do printf '%s\n' "$a"; done > "\#(dir.path)/args"; echo "[${MUXY_SESSION_ID-unset}][${CMUX_SURFACE_ID-unset}][${HOME:+home}]" > "\#(dir.path)/env""#, in: dir)
        let saved: [(String, String?)] = ["MUXY_SESSION_ID", "CMUX_SURFACE_ID"].map { (name: String) in (name, ProcessInfo.processInfo.environment[name]) }
        setenv("MUXY_SESSION_ID", "999", 1)
        setenv("CMUX_SURFACE_ID", "6F1B2C3D-0000", 1)
        defer { for (name, value) in saved { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }

        let text = "$(touch pwn); `id` | cat 'a' \"b\" \\n"
        #expect(AgentSend.execute(.run(tool, ["session", "send", "42", text])))
        #expect(try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8) == "session\nsend\n42\n\(text)\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8) == "[unset][unset][home]\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwn").path))
    }

    @Test func aCommandThatFailsOrIsMissingFailsTheStep() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!AgentSend.execute(.run(try stub("exit 3", in: dir), ["x"])))
        #expect(!AgentSend.execute(.run(dir.appendingPathComponent("missing"), ["x"])))
    }

    @Test func aPlanStopsAtTheFirstStepThatFails() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = try stub(#"echo "$1" >> "\#(dir.path)/calls"; [ "$1" = "bad" ] && exit 1; exit 0"#, in: dir)
        #expect(!AgentSender.live.run([.run(tool, ["one"]), .run(tool, ["bad"]), .run(tool, ["three"])]))
        #expect(try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8) == "one\nbad\n")
    }

    @Test func muxysListMustHoldTheSessionByTheWholeIdInTheFirstColumn() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = try stub(#"printf '1978299613479001934\taa29\tLive\ttrue\t/Users/me\n42\tbb\tLive\ttrue\t/tmp 1978299613479001934\n'"#, in: dir)
        #expect(AgentSend.execute(.listed(tool, ["session", "list"], id: "1978299613479001934")))
        #expect(AgentSend.execute(.listed(tool, ["session", "list"], id: "42")))
        // A prefix, a number inside a line and a session that isn't there are not the session.
        for id in ["197829961347900193", "78299613479001934", "4", "99999"] {
            #expect(!AgentSend.execute(.listed(tool, ["session", "list"], id: id)), "\(id)")
        }
        #expect(!AgentSend.execute(.listed(try stub("exit 1", in: dir), ["session", "list"], id: "42")))
    }

    private func serve(replying reply: String, at path: String) throws -> Process {
        let server = try StandIn.python("""
        import json, socket, sys
        s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(2)
        while True:
            c, _ = s.accept(); f = c.makefile("rwb")
            for line in f:
                request = json.loads(line)
                if sys.argv[2] == "error":
                    out = {"id": request["id"], "error": {"code": "pane_not_found", "message": "gone"}}
                else:
                    out = {"id": request["id"], "result": {"type": "ok"}}
                open(sys.argv[1] + ".log", "a").write(json.dumps(request, sort_keys=True) + "\\n")
                f.write((json.dumps(out) + "\\n").encode()); f.flush()
        """, arguments: [path, reply])
        let deadline = Date.now.addingTimeInterval(eventDeadline)
        while !FileManager.default.fileExists(atPath: path) && Date.now < deadline { usleep(20_000) }
        return server
    }

    @Test func herdrsRequestsAreWrittenToItsSocketAndAnErrorReplyFailsTheStep() throws {
        let path = "/tmp/nunsseop-send-\(UUID().uuidString.prefix(6)).sock"
        let server = try serve(replying: "ok", at: path)
        defer { server.terminate(); try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: path + ".log") }
        let steps = try #require(AgentSend.steps(.herdr(pane: "w1:p1", socket: path), text: "go on", submit: true, clis: TerminalCLIs()))
        #expect(AgentSender.live.run(steps))
        let logged = try String(contentsOfFile: path + ".log", encoding: .utf8).split(separator: "\n")
            .map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(logged.map { $0["method"] as? String } == ["pane.send_text", "pane.send_keys"])
        #expect((logged[0]["params"] as? [String: String]) == ["pane_id": "w1:p1", "text": "go on"])

        let failing = "/tmp/nunsseop-send-\(UUID().uuidString.prefix(6)).sock"
        let broken = try serve(replying: "error", at: failing)
        defer { broken.terminate(); try? FileManager.default.removeItem(atPath: failing); try? FileManager.default.removeItem(atPath: failing + ".log") }
        #expect(!AgentSend.execute(.socket(path: failing, requests: [steps.compactMap { step -> String? in
            if case .socket(_, let requests) = step { return requests[0] } else { return nil }
        }[0]])))
        // No socket, no session.
        #expect(!AgentSend.execute(.socket(path: "/tmp/nunsseop-send-missing.sock", requests: ["{}"])))
    }
}
