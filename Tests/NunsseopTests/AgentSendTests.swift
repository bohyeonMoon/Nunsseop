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
            return passes ? .sent : .failed
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

    @Test func theProcessReachesTheBoardForBothTools() {
        for kind in [AgentKind.claude, .codex] {
            let board = AgentBoard()
            let hooks = AgentHooks(board: board, agent: kind, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }, isAlive: { _ in true })
            hooks.apply(AgentEvent(session: "a", action: .working, agent: kind, pid: 4321, input: .muxy("42")), now: start)
            #expect(board.entries(now: start).first?.agent.pid == 4321)
            // A later event without one keeps it.
            hooks.apply(AgentEvent(session: "a", action: .finished, agent: kind, input: .muxy("42")), now: start)
            #expect(board.entries(now: start).first?.agent.pid == 4321)
        }
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

    @Test func herdrGetsOneSendInputRequestWithTheTextAndEnter() throws {
        let steps = try #require(AgentSend.steps(.herdr(pane: "w1:p2", socket: "/Users/me/.config/herdr/herdr.sock"), text: "hi \"there\"",
                                                 submit: true, clis: clis))
        guard steps.count == 1, case .socket(let path, let requests) = steps[0] else { Issue.record("not one socket step"); return }
        #expect(path == "/Users/me/.config/herdr/herdr.sock")
        // The socket closes after answering one request, so text and Return can't be two.
        #expect(requests.count == 1 && !requests[0].contains("\n"))
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(requests[0].utf8)) as? [String: Any])
        #expect(sent["method"] as? String == "pane.send_input")
        let params = sent["params"] as? [String: Any]
        #expect(params?.keys.sorted() == ["keys", "pane_id", "text"])
        #expect(params?["pane_id"] as? String == "w1:p2" && params?["text"] as? String == "hi \"there\"" && params?["keys"] as? [String] == ["enter"])
    }

    @Test func droppedPathsGoToHerdrWithoutKeys() throws {
        let steps = try #require(AgentSend.steps(.herdr(pane: "w1:p2", socket: "/tmp/h.sock"), text: "/tmp/a.png ", submit: false, clis: clis))
        guard steps.count == 1, case .socket(_, let requests) = steps[0], requests.count == 1 else { Issue.record("not one request"); return }
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(requests[0].utf8)) as? [String: Any])
        #expect(sent["method"] as? String == "pane.send_input")
        #expect(sent["params"] as? [String: String] == ["pane_id": "w1:p2", "text": "/tmp/a.png "])
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
                case .runInput(let tool, let arguments, _), .runWith(let tool, let arguments, _):
                    #expect(!["sh", "bash", "zsh", "dash", "env"].contains(tool.lastPathComponent))
                    #expect(!arguments.contains("-c"))
                case .script, .muxyFocus: break
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

/// Process trees and a Muxy list made up for the tests; the tree and the list can change while a test runs.
private final class FakeTerminals: @unchecked Sendable {
    static let muxyServer = "/Applications/Muxy.app/Contents/MacOS/muxy-server"
    static let cmuxApp = "/Applications/cmux.app/Contents/MacOS/cmux"

    /// A genuine Muxy session (claude 100, zsh 101, muxy-server 102, muxy-app 103) and a genuine cmux one (claude 200, zsh 201, app 202).
    static let genuine: [Int32: ProcessRecord] = [
        100: .init(parent: 101, executable: "/Users/me/.local/share/claude/versions/2.1", hasTTY: true),
        101: .init(parent: 102, executable: "/bin/zsh", hasTTY: true),
        102: .init(parent: 103, executable: muxyServer, hasTTY: false),
        103: .init(parent: 1, executable: "/Applications/Muxy.app/Contents/MacOS/muxy-app", hasTTY: false),
        200: .init(parent: 201, executable: "/Users/me/.local/share/claude/versions/2.1", hasTTY: true),
        201: .init(parent: 202, executable: "/bin/zsh", hasTTY: true),
        202: .init(parent: 1, executable: cmuxApp, hasTTY: false),
    ]

    private let lock = NSLock()
    private var records: [Int32: ProcessRecord]
    private var ids: [String]
    private var lists = 0
    private var onMain: [Bool] = []

    init(_ records: [Int32: ProcessRecord] = genuine, muxySessions: [String] = ["1", "2", "3", "4", "7", "42"]) {
        self.records = records
        ids = muxySessions
    }

    var processes: [Int32: ProcessRecord] {
        get { lock.withLock { records } }
        set { lock.withLock { records = newValue } }
    }
    var muxySessions: [String] {
        get { lock.withLock { ids } }
        set { lock.withLock { ids = newValue } }
    }
    /// How many times `muxy session list` was run.
    var listCalls: Int { lock.withLock { lists } }
    /// Whether any lookup or list ran on the main thread.
    var ranOnMainThread: Bool { lock.withLock { onMain.contains(true) } }
    var lookups: Int { lock.withLock { onMain.count } }

    var check: AgentTargetCheck {
        AgentTargetCheck(
            processes: ProcessTable { [self] pid in lock.withLock { onMain.append(Thread.isMainThread); return records[pid] } },
            muxyList: { [self] _ in
                lock.withLock { lists += 1; onMain.append(Thread.isMainThread); return ids.map { "\($0)\tname\tLive\ttrue\t/tmp\n" }.joined() }
            })
    }
}

@MainActor
struct AgentSendModelTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let clis = TerminalCLIs(muxy: URL(fileURLWithPath: "/m/muxy"), cmux: URL(fileURLWithPath: "/c/cmux"))
    fileprivate let terminals = FakeTerminals()

    /// A model on `board` whose terminals are the made-up ones; not refreshed yet.
    private func makeModel(_ board: AgentBoard, sender: AgentSender, clis: TerminalCLIs? = nil) -> AgentsTabModel {
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: sender, clis: { clis ?? self.clis }, targets: terminals.check)
        model.fixedRecent = []
        return model
    }

    /// Waits for the check of the sessions' terminals that a refresh starts.
    private func settle(_ model: AgentsTabModel) async {
        await eventually { !model.verifying }
    }

    private func make(_ recorder: Recorder, agents: [String: AgentBoard.Agent], clis: TerminalCLIs? = nil) async -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: agents, now: start)
        let model = makeModel(board, sender: recorder.sender, clis: clis)
        model.refresh(now: start)
        await settle(model)
        return model
    }

    /// The pid is that of a genuine session in the made-up tree for the input's terminal.
    private func agent(_ state: AgentBoard.State, finished: Bool = false, input: AgentInput? = .muxy("42"), pid: Int32? = nil) -> AgentBoard.Agent {
        let genuine: Int32? = switch input {
        case .muxy: 100
        case .cmux: 200
        case .herdr, .terminalApp, .iterm, .wezterm, .kitty, .ghostty, .orca, nil: nil
        }
        return AgentBoard.Agent(state: state, since: start, finished: finished, tool: "claude", input: input, pid: pid ?? genuine)
    }

    private func row(_ model: AgentsTabModel, _ id: String = "a") throws -> AgentRow {
        try #require(model.rows.first { $0.id == "hooks:claude|\(id)" })
    }

    @Test func aRowTakesInputWhenItsTerminalHasAnAPIAndNoPromptWaits() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.idle, input: .muxy("2")),
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
        let model = await make(recorder, agents: ["a": agent(.working)])
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
        let model = await make(recorder, agents: ["a": agent(.idle, input: .cmux("6F1B2C3D-0000"))])
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
        let model = await make(recorder, agents: ["a": agent(.waiting)])
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
        let model = await make(recorder, agents: ["a": agent(.working)])
        let drawn = try row(model)
        // The session starts asking for permission after the row was drawn.
        model.refresh(now: start)
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(.waiting)], now: start)
        let later = makeModel(board, sender: recorder.sender)
        later.refresh(now: start)
        await settle(later)
        #expect(!later.send(message: "hello", to: drawn))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func anEmptyMessageOrOneWithoutATargetSendsNothing() async throws {
        let recorder = Recorder()
        let model = await make(recorder, agents: ["a": agent(.working), "b": agent(.working, input: nil)])
        #expect(!model.send(message: " \n\t ", to: try row(model)))
        #expect(!model.send(message: "hello", to: try row(model, "b")))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func aFailureLeavesANoteOnTheRowThatGoesAway() async throws {
        let recorder = Recorder()
        recorder.passes = false
        let model = await make(recorder, agents: ["a": agent(.working)])
        let target = try row(model)
        #expect(model.send(message: "hello", to: target))
        await eventually { model.notes[target.id] != nil }
        #expect(model.notes[target.id] == String(localized: "Couldn't send to this session"))
        // A new send clears it.
        recorder.passes = true
        #expect(model.send(message: "again", to: target))
        #expect(model.notes[target.id] == nil)
    }

    @Test func aTerminalWhoseToolIsGoneLeavesANoteAndRunsNothing() async throws {
        let recorder = Recorder()
        let model = await make(recorder, agents: ["a": agent(.working, input: .cmux("6F1B2C3D-0000"))], clis: TerminalCLIs(muxy: clis.muxy, cmux: nil))
        let target = try row(model)
        #expect(model.send(message: "hello", to: target))
        #expect(model.notes[target.id] != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func theFieldHoldsTheKeyboardOnlyWhileItsRowTakesInputAndWhileTheTabShows() async throws {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(.working)], now: start)
        let model = makeModel(board, sender: Recorder().sender)
        model.refresh(now: start)
        await settle(model)
        let id = try row(model).id
        model.compose(try row(model))
        #expect(model.composing == id)
        model.cancelCompose()
        #expect(model.composing == nil)
        // The session starts waiting on a prompt: typing could answer it. It stays selected, and the footer says why.
        model.click(try row(model))
        model.compose(try row(model))
        board.replace(source: "hooks:claude", with: ["a": agent(.waiting)], now: start)
        model.refresh(now: start)
        #expect(model.composing == nil && model.selected == id)
        board.replace(source: "hooks:claude", with: ["a": agent(.working)], now: start)
        model.refresh(now: start)
        model.compose(try row(model))
        board.replace(source: "hooks:claude", with: [:], now: start)
        model.refresh(now: start)
        #expect(model.composing == nil && model.selected == nil)
    }

    @Test func leavingTheTabLetsGoOfTheField() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working)])
        model.isShowing = true
        model.compose(try row(model))
        #expect(model.composing != nil)
        model.isShowing = false
        #expect(model.composing == nil)
    }

    @Test func escapeAndLosingTheKeyboardCloseTheFieldOfThatRowOnly() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))])
        let a = try row(model, "a"), b = try row(model, "b")
        model.compose(a)
        model.cancelCompose(row: b.id)
        #expect(model.composing == a.id)
        model.cancelCompose(row: a.id)
        #expect(model.composing == nil)
        model.compose(a)
        model.cancelCompose()
        #expect(model.composing == nil && model.selected == a.id)
    }

    @Test func aPromptLeftOpenPastTheActiveWindowStillTakesNoInput() async throws {
        let recorder = Recorder()
        let board = AgentBoard()
        let hooks = AgentHooks(board: board, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }, isAlive: { _ in true })
        let model = makeModel(board, sender: recorder.sender)
        hooks.apply(AgentEvent(session: "a", action: .needsInput, pid: 100, input: .muxy("42")), now: start)
        model.refresh(now: start)
        await settle(model)
        let id = "hooks:claude|a"
        #expect(try #require(model.rows.first { $0.id == id }).state == .waiting)
        #expect(try !#require(model.rows.first { $0.id == id }).acceptsInput)

        // The clock turns the row idle, but nothing closed the dialog.
        let later = start.addingTimeInterval(AgentHooks.activeWindow + 60)
        model.refresh(now: later)
        await settle(model)
        let row = try #require(model.rows.first { $0.id == id })
        #expect(row.state == .idle && !row.acceptsInput && row.inputBlocked)
        #expect(!model.send(message: "no, stop", to: row))
        #expect(!model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: row))
        model.compose(row)
        #expect(model.composing == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)

        // A hook event that says the dialog is gone does.
        hooks.apply(AgentEvent(session: "a", action: .idle, pid: 100, input: .muxy("42")), now: later)
        model.refresh(now: later)
        await settle(model)
        #expect(try #require(model.rows.first { $0.id == id }).acceptsInput)
        hooks.apply(AgentEvent(session: "a", action: .needsInput, pid: 100, input: .muxy("42")), now: later)
        hooks.apply(AgentEvent(session: "a", action: .working, pid: 100, input: .muxy("42")), now: later)
        model.refresh(now: later)
        await settle(model)
        #expect(try #require(model.rows.first { $0.id == id }).acceptsInput)
    }

    @Test func aFinishedTurnPastItsWindowStillTakesInput() async throws {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": AgentBoard.Agent(state: .waiting, since: start, finished: true, tool: "claude",
                                                                      idleFrom: start.addingTimeInterval(600), input: .muxy("42"), pid: 100)], now: start)
        let model = makeModel(board, sender: Recorder().sender)
        model.refresh(now: start.addingTimeInterval(700))
        await settle(model)
        #expect(try row(model).state == .idle && row(model).acceptsInput)
    }

    @Test func nothingIsSentToATerminalWhereAnotherSessionMayHaveAPromptOpen() async throws {
        let recorder = Recorder()
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["parent": agent(.waiting), "child": agent(.working), "other": agent(.working, input: .muxy("7"))],
                      now: start)
        let model = makeModel(board, sender: recorder.sender)
        model.refresh(now: start)
        await settle(model)
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

    @Test func aPromptOpenInASharedTerminalPastTheWindowLetsGoOfTheSiblingsField() async throws {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["parent": agent(.working), "child": agent(.working)], now: start)
        let model = makeModel(board, sender: Recorder().sender)
        model.refresh(now: start)
        await settle(model)
        model.compose(try row(model, "child"))
        #expect(model.composing != nil)
        board.replace(source: "hooks:claude", with: ["parent": agent(.waiting), "child": agent(.working)], now: start)
        model.refresh(now: start)
        #expect(model.composing == nil)
    }

    // MARK: Selecting a row

    @Test func aClickSelectsTheRowAndOnlyOneRowIsSelected() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))])
        let a = try row(model, "a"), b = try row(model, "b")
        #expect(model.selected == nil)
        model.click(a)
        #expect(model.selected == a.id)
        model.click(b)
        #expect(model.selected == b.id)
        // A second click keeps it selected: nothing folds any more.
        model.click(b)
        #expect(model.selected == b.id)
    }

    @Test func aRowThatTakesNoInputIsSelectedToo() async throws {
        let model = await make(Recorder(), agents: ["w": agent(.waiting, input: .muxy("1")), "p": agent(.working, input: nil)])
        for id in ["w", "p"] {
            let blocked = try row(model, id)
            model.click(blocked)
            #expect(model.selected == blocked.id, Comment(rawValue: id))
        }
    }

    @Test func messageOpensTheFieldForThatRowAndNoOther() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))])
        let a = try row(model, "a"), b = try row(model, "b")
        model.click(a)
        model.compose(a)
        #expect(model.composing == a.id && model.selected == a.id)
        model.compose(b)
        #expect(model.composing == b.id && model.selected == b.id)
    }

    @Test func returnSendsToThatRowOnlyAndClosesTheField() async throws {
        let recorder = Recorder()
        let model = await make(recorder, agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))])
        let b = try row(model, "b")
        model.compose(b)
        // Nothing to send: the field stays.
        #expect(!model.submit(message: " \n ", to: b))
        #expect(model.composing == b.id)
        #expect(model.submit(message: "  run the tests\n", to: b))
        #expect(model.composing == nil && model.selected == b.id)
        await eventually { !recorder.recorded.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded == [[
            .listed(clis.muxy!, ["session", "list"], id: "2"),
            .run(clis.muxy!, ["session", "send", "2", "run the tests"]),
            .run(clis.muxy!, ["session", "send-keys", "2", "Enter"]),
        ]])
    }

    @Test func aRowThatTakesNoInputCannotMessageAndSaysWhy() async throws {
        let recorder = Recorder()
        let model = await make(recorder, agents: ["w": agent(.waiting, input: .muxy("1")), "p": agent(.working, input: nil)])
        let waiting = try row(model, "w"), plain = try row(model, "p")
        #expect(!waiting.acceptsInput && waiting.blockReason == AgentRow.InputBlock.prompt.message)
        #expect(!plain.acceptsInput && plain.blockReason != nil)
        for blocked in [waiting, plain] {
            model.click(blocked)
            model.compose(blocked)
            #expect(model.composing == nil && model.selected == blocked.id)
            #expect(!model.submit(message: "yes", to: blocked))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func aRowThatTakesInputHasNoReason() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working)])
        #expect(try row(model).acceptsInput && row(model).blockReason == nil)
    }

    @Test func aFailureNoteBelongsToItsRow() async throws {
        let recorder = Recorder()
        recorder.passes = false
        let model = await make(recorder, agents: ["a": agent(.working, input: .muxy("1"))])
        let a = try row(model)
        model.compose(a)
        #expect(model.submit(message: "hello", to: a))
        await eventually { model.notes[a.id] != nil }
        #expect(model.notes[a.id] == String(localized: "Couldn't send to this session"))
    }

    @Test func selectingAnotherRowEndsTypingButAClickOnTheSameRowDoesNot() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))])
        let a = try row(model, "a"), b = try row(model, "b")
        model.compose(a)
        model.click(a)
        #expect(model.composing == a.id && model.selected == a.id)
        model.click(b)
        #expect(model.composing == nil && model.selected == b.id)
    }

    @Test func aSelectedRowThatGoesAwayIsDeselected() async throws {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))], now: start)
        let model = makeModel(board, sender: Recorder().sender)
        model.refresh(now: start)
        await settle(model)
        model.click(try row(model, "b"))
        model.refresh(now: start)
        await settle(model)
        #expect(model.selected == "hooks:claude|b")
        board.replace(source: "hooks:claude", with: ["a": agent(.working, input: .muxy("1"))], now: start)
        model.refresh(now: start)
        await settle(model)
        #expect(model.selected == nil)
    }

    @Test func goToTerminalGoesToThatRowAndAClickOnTheRowDoesNot() async throws {
        final class Activations: @unchecked Sendable {
            private let lock = NSLock()
            private var apps: [String] = []
            func add(_ app: String) { lock.withLock { apps.append(app) } }
            var list: [String] { lock.withLock { apps } }
        }
        let activations = Activations()
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: [
            "a": AgentBoard.Agent(state: .working, since: start, tool: "claude", app: "com.apple.Terminal"),
            "b": AgentBoard.Agent(state: .working, since: start, tool: "claude", app: "com.apple.dt.Xcode"),
            "c": AgentBoard.Agent(state: .working, since: start, tool: "claude"),
        ], now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: Recorder().sender, clis: { clis }, targets: terminals.check,
                                   focuser: AgentFocuser(run: { _ in .sent }, activate: { activations.add($0) }, herdr: { _, _ in }))
        model.fixedRecent = []
        model.refresh(now: start)
        await settle(model)
        let a = try row(model, "a"), b = try row(model, "b"), c = try row(model, "c")
        #expect(a.focusable && b.focusable && !c.focusable)
        model.click(b)
        #expect(model.selected == b.id && activations.list.isEmpty)
        model.focus(a)
        #expect(activations.list == ["com.apple.Terminal"])
        // Going to a terminal leaves the selection as it was; a row with nowhere to go does nothing.
        #expect(model.selected == b.id)
        model.focus(c)
        #expect(activations.list == ["com.apple.Terminal"])
    }

    @Test func recentConversationsShowOnlyWhenNoSessionIsListed() async throws {
        let board = AgentBoard()
        let model = makeModel(board, sender: Recorder().sender)
        model.fixedRecent = AgentBoard.demoRecent()
        model.refresh(now: start)
        #expect(model.rows.isEmpty && model.showsRecent && !model.showsEmptyMessage)
        board.replace(source: "hooks:claude", with: ["a": agent(.working)], now: start)
        model.refresh(now: start)
        #expect(!model.rows.isEmpty && !model.recent.isEmpty && !model.showsRecent)
        board.replace(source: "hooks:claude", with: [:], now: start)
        model.refresh(now: start)
        #expect(model.showsRecent)
        model.fixedRecent = []
        model.refresh(now: start)
        #expect(!model.showsRecent && model.showsEmptyMessage)
    }

    @Test func theSharedComposerIsGone() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Nunsseop")
        let tab = try String(contentsOf: sources.appendingPathComponent("AgentsTab.swift"), encoding: .utf8)
        // The composer now is the footer's, with its recipient fixed to the row whose button was pressed (see `AgentComposer`).
        for gone in ["setComposing", "var draft", "goButton", "goHovering", "func submit()", "AgentActionStrip", "StripButton", "unfolded"] {
            #expect(!tab.contains(gone), Comment(rawValue: gone))
        }
    }

    @Test func theStripSentencesAreTranslatedIntoEveryLanguageAndTheComposerOnesAreGone() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for key in ["Go to terminal", "Message"] {
                let text = table[key] as? String ?? ""
                // French writes "Message" the same.
                #expect(!text.isEmpty && (text != key || language == "fr"), Comment(rawValue: "\(language): \(key)"))
            }
            #expect(table["To %@"] == nil && table["Send a message"] == nil, Comment(rawValue: language))
        }
    }

    // MARK: The keyboard and the footer

    /// A model whose focuser records the apps it was asked to bring forward; the rows' apps are made up.
    private func makeFocusing(_ agents: [String: AgentBoard.Agent], recent: [RecentConversation] = [],
                              onResume: @escaping (RecentConversation) -> Void = { _ in }) async -> (model: AgentsTabModel, apps: () -> [String]) {
        final class Activations: @unchecked Sendable {
            private let lock = NSLock()
            private var apps: [String] = []
            func add(_ app: String) { lock.withLock { apps.append(app) } }
            var list: [String] { lock.withLock { apps } }
        }
        let activations = Activations()
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: agents, now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   onResume: onResume, sender: Recorder().sender, clis: { clis }, targets: terminals.check,
                                   focuser: AgentFocuser(run: { _ in .sent }, activate: { activations.add($0) }, herdr: { _, _ in }))
        model.fixedRecent = recent
        model.refresh(now: start)
        await settle(model)
        return (model, { activations.list })
    }

    private func app(_ id: String) -> AgentBoard.Agent {
        AgentBoard.Agent(state: .working, since: start, tool: "claude", app: id)
    }

    @Test func downSelectsTheFirstRowUpTheLastAndBothStopAtTheEnds() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2")), "c": agent(.idle, input: .muxy("3"))])
        let ids = model.rows.map(\.id)
        #expect(model.selected == nil)
        #expect(model.perform(.down) && model.selected == ids[0])
        #expect(model.perform(.down) && model.selected == ids[1])
        #expect(model.perform(.down) && model.perform(.down) && model.selected == ids[2])
        #expect(model.perform(.up) && model.selected == ids[1])
        #expect(model.perform(.up) && model.perform(.up) && model.selected == ids[0])
        model.select(nil)
        #expect(model.perform(.up) && model.selected == ids[2])
        // With no rows there is nothing to walk.
        let empty = await make(Recorder(), agents: [:])
        #expect(!empty.perform(.down) && !empty.perform(.up) && empty.selected == nil)
    }

    @Test func movingTheSelectionEndsTypingToTheRowItLeft() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))])
        let b = try row(model, "b")
        model.compose(b)
        #expect(model.composing == b.id)
        model.perform(.up)
        #expect(model.composing == nil && model.selected == model.rows[0].id)
    }

    @Test func returnGoesToTheSelectedRowsTerminalAndDoesNothingWithoutASelection() async throws {
        let (model, apps) = await makeFocusing(["a": app("com.apple.Terminal"), "b": app("com.apple.dt.Xcode")])
        #expect(!model.perform(.activate) && apps().isEmpty)
        model.click(try row(model, "b"))
        #expect(apps().isEmpty)
        #expect(model.perform(.activate))
        #expect(apps() == ["com.apple.dt.Xcode"])
    }

    @Test func aDoubleClickGoesToTheTerminalAndASingleClickOnlySelects() async throws {
        let (model, apps) = await makeFocusing(["a": app("com.apple.Terminal")])
        let a = try row(model, "a")
        model.click(a, count: 1)
        #expect(model.selected == a.id && apps().isEmpty)
        model.click(a, count: 2)
        #expect(model.selected == a.id && apps() == ["com.apple.Terminal"])
    }

    @Test func commandMOpensTheFieldForTheSelectedRowThatTakesInput() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))])
        #expect(!model.perform(.message) && model.composing == nil)
        let b = try row(model, "b")
        model.select(b.id)
        #expect(model.perform(.message))
        #expect(model.composing == b.id && model.selected == b.id)
    }

    @Test func commandMOnARowThatTakesNoInputOnlyKeepsItSelectedForTheFooterToSayWhy() async throws {
        let model = await make(Recorder(), agents: ["w": agent(.waiting, input: .muxy("1"))])
        let waiting = try row(model, "w")
        model.select(waiting.id)
        #expect(model.perform(.message))
        #expect(model.composing == nil && model.selected == waiting.id)
        #expect(model.selectedRow?.blockReason == AgentRow.InputBlock.prompt.message)
    }

    @Test func theMessageButtonOfARowThatTakesNoInputSelectsItToo() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "p": agent(.working, input: nil)])
        let plain = try row(model, "p")
        model.compose(plain)
        #expect(model.composing == nil && model.selected == plain.id)
        #expect(model.selectedRow?.blockReason == plain.blockReason && plain.blockReason != nil)
    }

    @Test func theComposersRecipientIsTheRowWhoseButtonWasPressedAndEscapeClosesItWithoutSending() async throws {
        let recorder = Recorder()
        let model = await make(recorder, agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))])
        let a = try row(model, "a"), b = try row(model, "b")
        model.select(a.id)
        // The button of b, whichever row has the cursor.
        model.compose(b)
        #expect(model.composing == b.id && model.selected == b.id)
        // Escape (the notch's key monitor) and the × both come to this.
        model.cancelCompose()
        #expect(model.composing == nil && model.selected == b.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func theFooterTakesFilesOnlyWhenTheSelectedRowDoesElseWhenAnyRowDoes() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "w": agent(.waiting, input: .muxy("2"))])
        #expect(model.takesFiles)
        model.select(try row(model, "w").id)
        #expect(!model.takesFiles)
        model.select(try row(model, "a").id)
        #expect(model.takesFiles)
        let none = await make(Recorder(), agents: ["w": agent(.waiting, input: .muxy("2"))])
        #expect(!none.takesFiles)
    }

    @Test func aFailureNoteShowsInTheFooterUnderTheRowsTitle() async throws {
        let recorder = Recorder()
        recorder.passes = false
        let model = await make(recorder, agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2"))])
        #expect(model.footerNote == nil)
        let b = try row(model, "b")
        #expect(model.send(message: "hello", to: b))
        await eventually { model.notes[b.id] != nil }
        #expect(model.footerNote?.title == b.title && model.footerNote?.text == String(localized: "Couldn't send to this session"))
        // The selected row's note first; another's when nothing is selected.
        model.select(try row(model, "a").id)
        #expect(model.footerNote?.title == b.title)
    }

    @Test func withNoRowsTheKeysWalkTheRecentConversationsAndReturnResumesTheSelectedOne() async throws {
        final class Resumed: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [String] = []
            func add(_ id: String) { lock.withLock { ids.append(id) } }
            var list: [String] { lock.withLock { ids } }
        }
        let resumed = Resumed()
        let recent = AgentBoard.demoRecent(now: start)
        let (model, _) = await makeFocusing([:], recent: recent, onResume: { resumed.add($0.id) })
        #expect(model.showsRecent && model.rows.isEmpty)
        #expect(!model.perform(.activate) && resumed.list.isEmpty)
        #expect(model.perform(.down) && model.selected == recent[0].id)
        #expect(model.perform(.down) && model.selected == recent[1].id)
        #expect(model.perform(.down) && model.selected == recent[1].id)
        #expect(model.perform(.up) && model.selected == recent[0].id)
        #expect(model.perform(.activate) && resumed.list == [recent[0].id])
        // ⌘M means nothing on a conversation.
        #expect(!model.perform(.message) && model.composing == nil)
    }

    @Test func aSelectedConversationIsDeselectedWhenSessionsAppearOrItGoes() async throws {
        let board = AgentBoard()
        let model = makeModel(board, sender: Recorder().sender)
        let recent = AgentBoard.demoRecent(now: start)
        model.fixedRecent = recent
        model.refresh(now: start)
        model.select(recent[0].id)
        #expect(model.selected == recent[0].id)
        board.replace(source: "hooks:claude", with: ["a": agent(.working)], now: start)
        model.refresh(now: start)
        #expect(model.selected == nil)
        board.replace(source: "hooks:claude", with: [:], now: start)
        model.refresh(now: start)
        model.select(recent[1].id)
        model.fixedRecent = [recent[0]]
        model.refresh(now: start)
        #expect(model.selected == nil)
    }

    @Test func leavingTheTabClearsTheSelection() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working)])
        model.isShowing = true
        model.perform(.down)
        #expect(model.selected != nil)
        model.isShowing = false
        #expect(model.selected == nil)
    }

    // MARK: Verifying the target

    @Test func aRowOffersInputOnlyOnceItsTargetIsVerifiedExceptHerdrs() throws {
        let herdr = AgentBoard.Agent(state: .working, since: start, tool: "claude", input: .herdr(pane: "p", socket: "/tmp/h.sock"))
        let entry = AgentBoard.Entry(source: "hooks:claude", id: "a", agent: agent(.working))
        let unverified = AgentRow(entry, transcript: nil)
        #expect(!unverified.offersInput && !unverified.acceptsInput && !unverified.inputBlocked)
        let verified = AgentRow(entry, transcript: nil, inputVerified: true)
        #expect(verified.offersInput && verified.acceptsInput)
        let pane = AgentRow(AgentBoard.Entry(source: "herdr", id: "p", agent: herdr), transcript: nil)
        #expect(pane.offersInput && pane.acceptsInput)
    }

    @Test func aSessionThatIsAChildOfAnotherOnTheBoardOffersNoInputAndSendsNothing() async throws {
        let recorder = Recorder()
        // claude 100 (a session) -> node 110 (MCP server, keeps the tty) and claude -p 120 under it, with 100's variables.
        var tree = FakeTerminals.genuine
        tree[110] = .init(parent: 100, executable: "/usr/bin/node", hasTTY: true)
        tree[120] = .init(parent: 110, executable: "/Users/me/.local/share/claude/versions/2.1", hasTTY: true)
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(.working, pid: 100), "child": agent(.working, pid: 120)], now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: recorder.sender, clis: { clis }, targets: FakeTerminals(tree).check)
        model.fixedRecent = []
        model.refresh(now: start)
        await settle(model)
        #expect(try row(model, "a").offersInput)
        let child = try row(model, "child")
        #expect(!child.offersInput && !child.acceptsInput)
        #expect(!model.send(message: "hello", to: child))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func aRowWhoseTargetIsNotVerifiedHasNoBubbleTakesNoDropAndSendsNothing() async throws {
        let recorder = Recorder()
        // b: id of a session that is gone; c: no pid; d: no controlling terminal; e: in herdr's tree under the Muxy one; f: process gone.
        var tree = FakeTerminals.genuine
        tree[300] = .init(parent: 301, executable: "/usr/bin/node", hasTTY: false)
        tree[301] = .init(parent: 101, executable: "/bin/zsh", hasTTY: true)
        tree[400] = .init(parent: 401, executable: "/Users/me/.local/share/claude/versions/2.1", hasTTY: true)
        tree[401] = .init(parent: 402, executable: "/bin/zsh", hasTTY: true)
        tree[402] = .init(parent: 102, executable: "/Users/me/.local/bin/herdr", hasTTY: false)
        let terminals = FakeTerminals(tree)
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: [
            "a": agent(.working),
            "b": agent(.working, input: .muxy("9999")),
            "c": AgentBoard.Agent(state: .working, since: start, tool: "claude", input: .muxy("42")),
            "d": agent(.working, pid: 300),
            "e": agent(.working, pid: 400),
            "f": agent(.working, pid: 555),
        ], now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: recorder.sender, clis: { clis }, targets: terminals.check)
        model.fixedRecent = []
        model.refresh(now: start)
        await settle(model)
        #expect(try row(model, "a").offersInput)
        for id in ["b", "c", "d", "e", "f"] {
            let unverified = try row(model, id)
            #expect(!unverified.offersInput && !unverified.acceptsInput && !unverified.inputBlocked, Comment(rawValue: id))
            #expect(!model.send(message: "hello", to: unverified), Comment(rawValue: id))
            #expect(!model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: unverified), Comment(rawValue: id))
            model.compose(unverified)
            #expect(model.composing == nil && model.notes[unverified.id] == nil, Comment(rawValue: id))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
    }

    @Test func theTargetsAreCheckedOffTheMainThreadAndMuxysListIsReadOncePerRefresh() async throws {
        let model = await make(Recorder(), agents: ["a": agent(.working, input: .muxy("1")), "b": agent(.working, input: .muxy("2")),
                                                    "c": agent(.idle, input: .muxy("3")), "d": agent(.idle, input: .cmux("6F1B2C3D-0000"))])
        #expect(terminals.listCalls == 1)
        #expect(terminals.lookups > 0 && !terminals.ranOnMainThread)
        for id in ["a", "b", "c", "d"] { #expect(try row(model, id).offersInput, Comment(rawValue: id)) }
        // No Muxy session listed, no list to read.
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(.idle, input: .cmux("6F1B2C3D-0000"))], now: start)
        let cmuxOnly = FakeTerminals()
        let other = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: Recorder().sender, clis: { clis }, targets: cmuxOnly.check)
        other.fixedRecent = []
        other.refresh(now: start)
        await settle(other)
        #expect(cmuxOnly.listCalls == 0 && other.rows.first?.offersInput == true)
    }

    @Test func aMuxyToolThatIsMissingOrFailingVerifiesNoMuxySession() async throws {
        let none = await make(Recorder(), agents: ["a": agent(.working)], clis: TerminalCLIs(muxy: nil, cmux: nil))
        #expect(try !row(none).offersInput)
        terminals.muxySessions = []
        let empty = await make(Recorder(), agents: ["a": agent(.working)])
        #expect(try !row(empty).offersInput)
    }

    @Test func theProcessIsLookedAtAgainRightBeforeSendingAndAGoneOneLeavesANoteAndNoBubble() async throws {
        let recorder = Recorder()
        let model = await make(recorder, agents: ["a": agent(.working)])
        let drawn = try row(model)
        #expect(drawn.offersInput)
        // The session ends after the row was drawn and before the click on Send.
        terminals.processes = [:]
        #expect(model.send(message: "hello", to: drawn))
        await eventually { model.notes[drawn.id] != nil }
        #expect(model.notes[drawn.id] == String(localized: "Couldn't send to this session"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
        // The row is checked again, so its bubble goes.
        await settle(model)
        await eventually { (try? row(model))?.offersInput == false }
        #expect(try !row(model).offersInput)
    }

    @Test func aFailedSendChecksTheTargetAgainAndTheBubbleGoesWhenTheSessionIsGone() async throws {
        let recorder = Recorder()
        recorder.passes = false
        let model = await make(recorder, agents: ["a": agent(.working)])
        let target = try row(model)
        // Muxy closed the session; the process is still there.
        terminals.muxySessions = []
        #expect(model.send(message: "hello", to: target))
        await eventually { model.notes[target.id] != nil }
        #expect(model.notes[target.id] == String(localized: "Couldn't send to this session"))
        await eventually { (try? row(model))?.offersInput == false }
        let after = try row(model)
        #expect(!after.offersInput && !after.acceptsInput)
        model.compose(after)
        #expect(model.composing == nil)
    }

    @Test func aFailedSendToAStillVerifiedSessionKeepsTheBubble() async throws {
        let recorder = Recorder()
        recorder.passes = false
        let model = await make(recorder, agents: ["a": agent(.working)])
        let target = try row(model)
        #expect(model.send(message: "hello", to: target))
        await eventually { model.notes[target.id] != nil }
        await settle(model)
        #expect(try row(model).offersInput)
    }

    @Test func theFailureNoteIsTranslatedIntoEveryLanguageAndTheOldOneIsGone() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            let text = table["Couldn't send to this session"] as? String ?? ""
            #expect(!text.isEmpty && text != "Couldn't send to this session", Comment(rawValue: language))
            #expect(table["Couldn't send. Is the terminal still open?"] == nil, Comment(rawValue: language))
        }
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

/// Which terminal a session's process runs in, from made-up process trees.
struct AgentTargetCheckTests {
    typealias Tree = [Int32: ProcessRecord]
    let muxyServer = FakeTerminals.muxyServer
    let cmuxApp = FakeTerminals.cmuxApp
    let sessions: Set<String> = ["42", "7"]

    private func check(_ tree: Tree = FakeTerminals.genuine) -> AgentTargetCheck {
        AgentTargetCheck(processes: ProcessTable { tree[$0] }, muxyList: { _ in nil })
    }

    private func claude(parent: Int32, tty: Bool = true) -> ProcessRecord {
        .init(parent: parent, executable: "/Users/me/.local/share/claude/versions/2.1", hasTTY: tty)
    }

    private func shell(parent: Int32) -> ProcessRecord { .init(parent: parent, executable: "/bin/zsh", hasTTY: true) }

    private func between(_ path: String, host: String, hostIsMuxy: Bool = true) -> Tree {
        // claude 1 -> zsh 2 -> [path] 3 -> zsh 4 -> host 5
        [1: claude(parent: 2), 2: shell(parent: 3), 3: .init(parent: 4, executable: path, hasTTY: true), 4: shell(parent: 5),
         5: .init(parent: 1, executable: host, hasTTY: false)]
    }

    @Test func aGenuineMuxySessionIsVerifiedWhenItsIdIsListed() {
        #expect(check().verified(.muxy("42"), pid: 100, muxySessions: sessions))
        // The id must be in the list: a stale id from a terminal that is gone is not.
        #expect(!check().verified(.muxy("9999"), pid: 100, muxySessions: sessions))
        #expect(!check().verified(.muxy("42"), pid: 100, muxySessions: []))
        #expect(!check().verified(.muxy("42"), pid: 100, muxySessions: nil))
    }

    @Test func aGenuineCmuxSessionIsVerifiedByItsAncestors() {
        #expect(check().verified(.cmux("6F1B2C3D-0000"), pid: 200, muxySessions: nil))
        // Each terminal's process is the one that counts: the Muxy chain is not cmux's, nor the other way round.
        #expect(!check().verified(.cmux("6F1B2C3D-0000"), pid: 100, muxySessions: nil))
        #expect(!check().verified(.muxy("42"), pid: 200, muxySessions: sessions))
    }

    @Test func noPidADeadPidOrNoControllingTerminalMeansNoTarget() {
        #expect(!check().verified(.muxy("42"), pid: nil, muxySessions: sessions))
        #expect(!check().verified(.muxy("42"), pid: 31337, muxySessions: sessions))
        // claude's background children (an observer started by a session) have no terminal, with the parent's variables.
        var tree = FakeTerminals.genuine
        tree[110] = claude(parent: 100, tty: false)
        #expect(!check(tree).verified(.muxy("42"), pid: 110, muxySessions: sessions))
        tree[110] = claude(parent: 100, tty: true)
        #expect(check(tree).verified(.muxy("42"), pid: 110, muxySessions: sessions))
        // A link of the chain that is gone breaks it.
        tree[101] = nil
        #expect(!check(tree).verified(.muxy("42"), pid: 100, muxySessions: sessions))
    }

    @Test func aChildOfAnotherBoardSessionIsNotATargetEvenWithATerminal() {
        // claude 10 (a session) -> node 11 (an MCP server, inherits the tty) and claude -p 12 under it: both carry 10's variables.
        var tree = FakeTerminals.genuine
        tree[10] = claude(parent: 100)
        tree[11] = .init(parent: 10, executable: "/usr/bin/node", hasTTY: true)
        tree[12] = claude(parent: 11)
        #expect(check(tree).verified(.muxy("42"), pid: 10, muxySessions: sessions, others: [10, 12]))
        #expect(!check(tree).verified(.muxy("42"), pid: 12, muxySessions: sessions, others: [10, 12]))
        #expect(!check(tree).hosted(.muxy("42"), pid: 12, others: [10, 12]))
        // Without the parent on the board nothing says so, and the chain is as before.
        #expect(check(tree).verified(.muxy("42"), pid: 12, muxySessions: sessions, others: [12]))
    }

    @Test func aSessionWhoseOwnExecutableIsInAnAppBundleIsStillVerified() {
        // Only what a session runs under says which terminal it is in, not the bundle its own binary lives in.
        var tree = FakeTerminals.genuine
        tree[100] = .init(parent: 101, executable: "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude", hasTTY: true)
        #expect(check(tree).verified(.muxy("42"), pid: 100, muxySessions: sessions, others: [100]))
        // But one launched by an app bundle is in that app.
        tree[101] = .init(parent: 102, executable: "/Applications/Claude.app/Contents/Helpers/helper", hasTTY: true)
        #expect(!check(tree).verified(.muxy("42"), pid: 100, muxySessions: sessions, others: [100]))
    }

    @Test func anotherTerminalOrMultiplexerOnTheWayMeansTheSessionIsNotInTheNamedTerminal() {
        let others = ["/Users/me/.local/bin/herdr", "/opt/homebrew/bin/tmux", "/opt/homebrew/bin/zellij", "/usr/bin/screen",
                      "/Applications/Ghostty.app/Contents/MacOS/ghostty", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                      "/Applications/iTerm.app/Contents/MacOS/iTerm2", "/Applications/cmux.app/Contents/MacOS/cmux",
                      "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui", "/Applications/Muxy.app/Contents/MacOS/muxy-app"]
        for path in others {
            #expect(!check(between(path, host: muxyServer)).verified(.muxy("42"), pid: 1, muxySessions: sessions), Comment(rawValue: path))
        }
        for path in others where !path.contains("cmux") {
            #expect(!check(between(path, host: cmuxApp)).verified(.cmux("6F1B2C3D-0000"), pid: 1, muxySessions: nil), Comment(rawValue: path))
        }
        // The same without the other terminal in the middle is verified.
        let plain = between("/usr/bin/caffeinate", host: muxyServer)
        #expect(check(plain).verified(.muxy("42"), pid: 1, muxySessions: sessions))
        #expect(check(between("/usr/bin/caffeinate", host: cmuxApp)).verified(.cmux("6F1B2C3D-0000"), pid: 1, muxySessions: nil))
    }

    @Test func aSessionInAHerdrPaneStartedFromAnOldMuxyTerminalIsNotVerified() {
        // claude -> zsh -> herdr server (a daemon: its parent is launchd), with MUXY_SESSION_ID left over from the terminal that started herdr.
        let tree: Tree = [1: claude(parent: 2), 2: shell(parent: 3), 3: .init(parent: 1, executable: "/Users/me/.local/bin/herdr", hasTTY: false)]
        #expect(!check(tree).verified(.muxy("42"), pid: 1, muxySessions: sessions))
        #expect(!check(tree).verified(.cmux("6F1B2C3D-0000"), pid: 1, muxySessions: nil))
    }

    @Test func aLoopOrAVeryLongChainEndsInNoTarget() {
        let loop: Tree = [1: claude(parent: 2), 2: shell(parent: 1)]
        #expect(!check(loop).verified(.muxy("42"), pid: 1, muxySessions: sessions))
        var deep: Tree = [:]
        for pid in Int32(1)..<200 { deep[pid] = pid == 1 ? claude(parent: pid + 1) : shell(parent: pid + 1) }
        deep[200] = .init(parent: 1_000, executable: muxyServer, hasTTY: false)
        #expect(!check(deep).verified(.muxy("42"), pid: 1, muxySessions: sessions))
    }

    @Test func herdrPanesNeedNoCheckAsHerdrsOwnListIsTheProof() {
        #expect(check([:]).verified(.herdr(pane: "p", socket: "/tmp/h.sock"), pid: nil, muxySessions: nil))
    }

    @Test func theHostsAreRecognizedByTheirExecutables() {
        #expect(AgentTargetCheck.isMuxyServer("/Applications/Muxy.app/Contents/MacOS/muxy-server"))
        #expect(AgentTargetCheck.isMuxyServer("/Users/me/Applications/Muxy.app/Contents/MacOS/muxy-server"))
        #expect(!AgentTargetCheck.isMuxyServer("/Applications/Muxy.app/Contents/MacOS/muxy-app"))
        #expect(!AgentTargetCheck.isMuxyServer("/tmp/muxy-server"))
        #expect(AgentTargetCheck.isCmuxApp("/Applications/cmux.app/Contents/MacOS/cmux"))
        #expect(AgentTargetCheck.isCmuxApp("/Applications/cmux DEV.app/Contents/MacOS/cmux DEV"))
        #expect(!AgentTargetCheck.isCmuxApp("/Applications/cmux.app/Contents/Resources/bin/cmux"))
        #expect(!AgentTargetCheck.isCmuxApp("/usr/local/bin/cmux"))
        #expect(!AgentTargetCheck.isCmuxApp("/Applications/Ghostty.app/Contents/MacOS/ghostty"))
    }

    @Test func muxysListGivesTheFirstColumnOfEachLine() {
        let listing = "1978299613479001934\tmain\tLive\ttrue\t/Users/me\n42\tbb\tLive\ttrue\t/tmp 7\n"
        let check = AgentTargetCheck(processes: ProcessTable { _ in nil }, muxyList: { _ in listing })
        #expect(check.muxySessions(cli: URL(fileURLWithPath: "/m/muxy")) == ["1978299613479001934", "42"])
        #expect(check.muxySessions(cli: nil) == nil)
        #expect(AgentTargetCheck(processes: ProcessTable { _ in nil }, muxyList: { _ in nil }).muxySessions(cli: URL(fileURLWithPath: "/m/muxy")) == nil)
    }

    @Test func theLiveTableReadsRealProcesses() throws {
        let me = try #require(ProcessTable.live.lookup(getpid()))
        #expect(me.parent == getppid() && me.executable?.isEmpty == false)
        #expect(ProcessTable.live.lookup(Int32.max - 7) == nil)
        // A process of a session of its own has no controlling terminal (it may be in one already, from how it was started).
        let output = Pipe()
        let child = try StandIn.python("try:\n    os.setsid()\nexcept OSError:\n    pass\nprint('ready', flush=True)\ntime.sleep(60)", output: output)
        defer { child.terminate() }
        _ = output.fileHandleForReading.availableData
        let detached = try #require(ProcessTable.live.lookup(child.processIdentifier))
        #expect(!detached.hasTTY && detached.parent == getpid())
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

    @Test func theCommandsOfTheVersionBeforeWezTermKittyAndITermHeadersAreReplacedInPlace() throws {
        let headers = #"-H "X-Wezterm: ${WEZTERM_PANE}" -H "X-Wezterm-Socket: ${WEZTERM_UNIX_SOCKET}" -H "X-Kitty: ${KITTY_WINDOW_ID}" -H "X-Kitty-Socket: ${KITTY_LISTEN_ON}" -H "X-Iterm: ${ITERM_SESSION_ID}" "#
        for agent in [AgentKind.claude, .codex] {
            let current = NotifyServer.agentHookCommand(for: agent)
            let previous = current.replacingOccurrences(of: headers, with: "")
            #expect(previous != current && !previous.contains("X-Wezterm") && previous.contains("X-Muxy"))
            let table: JSONHook.Table = [("Stop", current), ("Interrupt", current)]
            let mine: [String: Any] = ["hooks": [["type": "command", "command": "mine.sh"]]]
            let before: [String: Any] = ["hooks": ["Stop": [mine, ours(previous), mine], "Interrupt": [ours(previous)]]]
            let after = try #require(try JSONHook.updating(table, in: before))
            // The same groups at the same positions, only the command replaced.
            #expect(commands(after, "Stop") == ["mine.sh", current, "mine.sh"] && commands(after, "Interrupt") == [current])
            #expect(groups(after, "Stop")[0] as NSDictionary == mine as NSDictionary)
            #expect(JSONHook.isCurrent(table, in: after))
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
        #expect(AgentSender.live.run([.run(tool, ["one"]), .run(tool, ["bad"]), .run(tool, ["three"])]) == .failed)
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

    /// herdr's socket: answers one request per connection, then closes it. Every request is logged with the number of its connection.
    private func serve(replying reply: String, at path: String) throws -> Process {
        let server = try StandIn.python("""
        import json, socket, sys
        s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
        n = 0
        while True:
            c, _ = s.accept(); n += 1; f = c.makefile("rwb")
            line = f.readline()
            if not line:
                c.close(); continue
            request = json.loads(line)
            if sys.argv[2] == "error":
                out = {"id": "", "error": {"code": "pane_not_found", "message": "gone"}}
            else:
                out = {"id": request["id"], "result": {"type": "ok"}}
            open(sys.argv[1] + ".log", "a").write(json.dumps({"connection": n, "request": request}, sort_keys=True) + "\\n")
            f.write((json.dumps(out) + "\\n").encode()); f.flush()
            c.close()
        """, arguments: [path, reply])
        let deadline = Date.now.addingTimeInterval(eventDeadline)
        while !FileManager.default.fileExists(atPath: path) && Date.now < deadline { usleep(20_000) }
        return server
    }

    private func logged(_ path: String) throws -> [(connection: Int, request: [String: Any])] {
        try String(contentsOfFile: path + ".log", encoding: .utf8).split(separator: "\n").map { line in
            let entry = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return (entry["connection"] as? Int ?? 0, entry["request"] as? [String: Any] ?? [:])
        }
    }

    @Test func herdrGetsOneSendInputRequestOnOneConnectionAndTheSendPasses() throws {
        let path = "/tmp/nunsseop-send-\(UUID().uuidString.prefix(6)).sock"
        let server = try serve(replying: "ok", at: path)
        defer { server.terminate(); try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: path + ".log") }
        let steps = try #require(AgentSend.steps(.herdr(pane: "w1:p1", socket: path), text: "go on", submit: true, clis: TerminalCLIs()))
        #expect(AgentSender.live.run(steps) == .sent)
        let requests = try logged(path)
        #expect(requests.count == 1 && requests[0].connection == 1)
        #expect(requests[0].request["method"] as? String == "pane.send_input")
        let params = requests[0].request["params"] as? [String: Any]
        #expect(params?["pane_id"] as? String == "w1:p1" && params?["text"] as? String == "go on" && params?["keys"] as? [String] == ["enter"])

        // A dropped path goes without keys.
        let drop = try #require(AgentSend.steps(.herdr(pane: "w1:p1", socket: path), text: "/tmp/a.png ", submit: false, clis: TerminalCLIs()))
        #expect(AgentSender.live.run(drop) == .sent)
        let all = try logged(path)
        #expect(all.count == 2 && all[1].connection == 2)
        #expect((all[1].request["params"] as? [String: String]) == ["pane_id": "w1:p1", "text": "/tmp/a.png "])
    }

    @Test func eachRequestOfASocketStepGetsAConnectionOfItsOwn() throws {
        let path = "/tmp/nunsseop-send-\(UUID().uuidString.prefix(6)).sock"
        let server = try serve(replying: "ok", at: path)
        defer { server.terminate(); try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: path + ".log") }
        // The stand-in closes after one reply, as herdr does: on one connection the second request would find it closed.
        let requests = ["{\"id\":\"one\",\"method\":\"a\"}", "{\"id\":\"two\",\"method\":\"b\"}", "{\"id\":\"three\",\"method\":\"c\"}"]
        #expect(AgentSend.execute(.socket(path: path, requests: requests)))
        let seen = try logged(path)
        #expect(seen.map(\.connection) == [1, 2, 3])
        #expect(seen.map { $0.request["id"] as? String } == ["one", "two", "three"])
    }

    @Test func anErrorReplyOrAMissingSocketFailsTheStep() throws {
        let failing = "/tmp/nunsseop-send-\(UUID().uuidString.prefix(6)).sock"
        let broken = try serve(replying: "error", at: failing)
        defer { broken.terminate(); try? FileManager.default.removeItem(atPath: failing); try? FileManager.default.removeItem(atPath: failing + ".log") }
        let steps = try #require(AgentSend.steps(.herdr(pane: "gone", socket: failing), text: "x", submit: true, clis: TerminalCLIs()))
        #expect(AgentSender.live.run(steps) == .failed)
        #expect(try logged(failing).count == 1)
        // An error stops the step: the requests after it aren't sent.
        #expect(!AgentSend.execute(.socket(path: failing, requests: ["{\"id\":\"a\"}", "{\"id\":\"b\"}"])))
        #expect(try logged(failing).count == 2)
        // No socket, no session.
        #expect(!AgentSend.execute(.socket(path: "/tmp/nunsseop-send-missing.sock", requests: ["{}"])))
    }
}
