import Foundation
import Testing
@testable import Nunsseop

// The terminal of a session whose hook named none, found in its process's own environment. Nothing here starts a terminal or types
// into one: the readers and process trees are made up, except one test that reads a child it starts itself (/bin/sleep).

/// A `KERN_PROCARGS2` buffer: argc, the path, NUL padding, the arguments, the environment.
private func procargs(argc: Int32? = nil, path: String = "/bin/sleep", args: [String] = ["sleep", "30"], env: [String], padding: Int = 3,
                      terminated: Bool = true) -> [UInt8] {
    let count = argc ?? Int32(args.count)
    var bytes = withUnsafeBytes(of: count.littleEndian) { Array($0) }
    bytes += Array(path.utf8) + [UInt8](repeating: 0, count: 1 + padding)
    for arg in args { bytes += Array(arg.utf8) + [0] }
    for (index, variable) in env.enumerated() {
        bytes += Array(variable.utf8)
        if terminated || index < env.count - 1 { bytes.append(0) }
    }
    return bytes
}

private func parse(_ bytes: [UInt8]) -> [String: String] { ProcessEnvironment.parse(bytes[...]) }

struct ProcessEnvironmentParseTests {
    @Test func onlyTheListedVariablesAreTaken() {
        let env = ["PATH=/usr/bin", "ANTHROPIC_API_KEY=sk-secret", "MUXY_SESSION_ID=42", "HOME=/Users/me", "CMUX_SURFACE_ID=6F1B2C3D-0000",
                   "TMUX=/tmp/tmux-501/default,1,0", "NOT_MUXY_SESSION_ID=7", "muxy_session_id=8"]
        #expect(parse(procargs(env: env)) == ["MUXY_SESSION_ID": "42", "CMUX_SURFACE_ID": "6F1B2C3D-0000", "TMUX": "/tmp/tmux-501/default,1,0"])
        #expect(parse(procargs(env: ["PATH=/usr/bin", "SECRET=x"])).isEmpty)
    }

    @Test func theFirstOfARepeatedVariableWinsAndAnEmptyValueStaysEmpty() {
        #expect(parse(procargs(env: ["MUXY_SESSION_ID=1", "MUXY_SESSION_ID=2"])) == ["MUXY_SESSION_ID": "1"])
        #expect(parse(procargs(env: ["KITTY_WINDOW_ID=", "KITTY_WINDOW_ID=2"])) == ["KITTY_WINDOW_ID": ""])
        // The value runs to the end of the string, `=` signs included.
        #expect(parse(procargs(env: ["KITTY_LISTEN_ON=unix:/tmp/k=1"])) == ["KITTY_LISTEN_ON": "unix:/tmp/k=1"])
    }

    @Test func argumentsAreNeverTakenForVariablesAndPaddingIsAnyLength() {
        #expect(parse(procargs(args: ["env", "MUXY_SESSION_ID=9"], env: ["WEZTERM_PANE=3"])) == ["WEZTERM_PANE": "3"])
        for padding in [0, 1, 7, 8, 20] { #expect(parse(procargs(env: ["WEZTERM_PANE=3"], padding: padding)) == ["WEZTERM_PANE": "3"], "\(padding)") }
        #expect(parse(procargs(args: [], env: ["WEZTERM_PANE=3"])) == ["WEZTERM_PANE": "3"])
        // The extra NULs the kernel leaves at the end are nothing.
        #expect(parse(procargs(env: ["WEZTERM_PANE=3"]) + [0, 0, 0, 0]) == ["WEZTERM_PANE": "3"])
    }

    @Test func aStringTheBufferCutsOffIsDroppedNotTakenShort() {
        #expect(parse(procargs(env: ["KITTY_WINDOW_ID=3", "MUXY_SESSION_ID=123"], terminated: false)) == ["KITTY_WINDOW_ID": "3"])
        #expect(parse(procargs(env: ["MUXY_SESSION_ID=123"], terminated: false)).isEmpty)
    }

    @Test func aMalformedBufferGivesNothingOrWhatCameBeforeTheFlaw() {
        let whole = procargs(env: ["MUXY_SESSION_ID=42"])
        // Cut anywhere short of the variable and its terminator: nothing, never a crash.
        for length in 0..<whole.count { #expect(parse(Array(whole[..<length])).isEmpty, "\(length)") }
        #expect(parse(whole) == ["MUXY_SESSION_ID": "42"])
        // An argc larger than the arguments there are, negative, or absurd.
        #expect(parse(procargs(argc: 5, env: ["MUXY_SESSION_ID=42"])).isEmpty)
        #expect(parse(procargs(argc: -1, env: ["MUXY_SESSION_ID=42"])).isEmpty)
        #expect(parse(procargs(argc: Int32.max, env: ["MUXY_SESSION_ID=42"])).isEmpty)
        #expect(parse([]).isEmpty && parse([2, 0, 0]).isEmpty && parse([0, 0, 0, 0]).isEmpty)
        #expect(parse([UInt8](repeating: 0xff, count: 64)).isEmpty)
        #expect(parse([UInt8](repeating: 0, count: 4096)).isEmpty)
        #expect(parse(Array("MUXY_SESSION_ID=42".utf8)).isEmpty)
        // Strings without `=`, empty ones and bytes that aren't UTF-8 are skipped or come out for the parsers to refuse.
        #expect(parse(procargs(env: ["", "NOEQUALS", "=x", "MUXY_SESSION_ID=42"])) == ["MUXY_SESSION_ID": "42"])
        let junk = procargs(env: ["MUXY_SESSION_ID=4"]) + [0xff, 0xfe, 0]
        #expect(parse(junk) == ["MUXY_SESSION_ID": "4"])
        let binary = Array("KITTY_LISTEN_ON=".utf8) + [0xff, 0xfe, 0]
        let value = parse(Array(procargs(env: []) + binary))["KITTY_LISTEN_ON"]
        #expect(value != nil && AgentInput.kittySocket(value) == nil)
    }

    @Test func aReaderIsFilteredToTheListedVariablesToo() {
        let environment = ProcessEnvironment { _ in ["MUXY_SESSION_ID": "42", "AWS_SECRET_ACCESS_KEY": "x"] }
        #expect(environment.variables(of: 100) == ["MUXY_SESSION_ID": "42"])
        #expect(ProcessEnvironment { _ in nil }.variables(of: 100).isEmpty)
    }

    /// Reads the environment of a child that this test starts, by its pid, with the real `sysctl`; nothing else's. macOS gives no
    /// environment for a system binary such as /bin/sleep itself, so the child is a copy of it, signed ad hoc.
    @Test func theLiveReaderReadsAChildsOwnEnvironmentAndOnlyTheListedVariables() async throws {
        let sleep = try StubTool.signedCopy(of: "/bin/sleep", named: "sleep")

        let child = Process()
        child.executableURL = sleep
        child.arguments = ["30"]
        child.environment = ["MUXY_SESSION_ID": "123", "KITTY_LISTEN_ON": "unix:/tmp/kitty-1", "PRIVATE_TOKEN": "hunter2", "TMUX": ""]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let pid = child.processIdentifier
        let expected = ["MUXY_SESSION_ID": "123", "KITTY_LISTEN_ON": "unix:/tmp/kitty-1", "TMUX": ""]
        // The child may not have exec'd yet, when it has no environment of its own to read.
        var raw: [String: String]?
        await eventually {
            raw = ProcessEnvironment.live.read(pid)
            return raw == expected
        }
        #expect(raw == expected)
        #expect(ProcessEnvironment.live.variables(of: pid) == expected)
    }

    @Test func theLiveReaderFailsQuietlyForAProcessThatIsNotThere() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(ProcessEnvironment.live.read(child.processIdentifier) == nil)
        #expect(ProcessEnvironment.live.read(0) == nil && ProcessEnvironment.live.read(1) == nil && ProcessEnvironment.live.read(-5) == nil)
    }
}

struct EnvironmentInputTests {
    private let wezSocket = "/Users/me/.local/share/wezterm/gui-sock-1200"
    private let kittySocket = "unix:/tmp/kitty-4242"
    private let kittyExe = "/Applications/kitty.app/Contents/MacOS/kitty"
    private let weztermGUI = "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui"

    @Test func theVariablesGoThroughTheSameParsersAsTheHookHeaders() {
        #expect(AgentHook.input(environment: ["MUXY_SESSION_ID": "42"], app: nil) == .muxy("42"))
        #expect(AgentHook.input(environment: ["CMUX_SURFACE_ID": "6F1B2C3D-0000"], app: nil) == .cmux("6F1B2C3D-0000"))
        #expect(AgentHook.input(environment: ["WEZTERM_PANE": "7", "WEZTERM_UNIX_SOCKET": wezSocket], app: nil) == .wezterm(pane: "7", socket: wezSocket))
        #expect(AgentHook.input(environment: ["KITTY_WINDOW_ID": "3", "KITTY_LISTEN_ON": kittySocket], app: nil) == .kitty(window: "3", socket: kittySocket))
        let bad: [[String: String]] = [
            ["MUXY_SESSION_ID": "4 2"], ["MUXY_SESSION_ID": "4\n2"], ["MUXY_SESSION_ID": ""], ["MUXY_SESSION_ID": String(repeating: "9", count: 21)],
            ["CMUX_SURFACE_ID": "../x"], ["CMUX_SURFACE_ID": "-6F1B2C3D-0000"], ["CMUX_SURFACE_ID": "abc"],
            ["WEZTERM_PANE": "7"], ["WEZTERM_PANE": "7;id", "WEZTERM_UNIX_SOCKET": wezSocket], ["WEZTERM_PANE": "7", "WEZTERM_UNIX_SOCKET": "unix:/tmp/x"],
            ["KITTY_WINDOW_ID": "3"], ["KITTY_WINDOW_ID": "3", "KITTY_LISTEN_ON": "tcp:localhost:5000"], ["KITTY_WINDOW_ID": "x", "KITTY_LISTEN_ON": kittySocket],
            [:],
        ]
        for environment in bad { #expect(AgentHook.input(environment: environment, app: nil) == nil, "\(environment)") }
    }

    @Test func aHerdrPaneOrAMultiplexerMeansNoTargetWhateverElseIsThere() {
        let muxy = ["MUXY_SESSION_ID": "42"]
        #expect(AgentHook.input(environment: muxy, app: nil) == .muxy("42"))
        for name in ["HERDR_PANE_ID", "TMUX", "ZELLIJ", "STY"] {
            #expect(AgentHook.input(environment: muxy.merging([name: "1"]) { $1 }, app: nil) == nil, "\(name)")
        }
        // Set but empty is not set, as `${TMUX:+1}` has it.
        #expect(AgentHook.input(environment: muxy.merging(["TMUX": "", "HERDR_PANE_ID": ""]) { $1 }, app: nil) == .muxy("42"))
    }

    @Test func theCandidatesKeepTheHooksPriority() {
        let all = ["MUXY_SESSION_ID": "1", "CMUX_SURFACE_ID": "6F1B2C3D-0000", "WEZTERM_PANE": "7", "WEZTERM_UNIX_SOCKET": wezSocket,
                   "KITTY_WINDOW_ID": "3", "KITTY_LISTEN_ON": kittySocket, "ITERM_SESSION_ID": "w0t0p0:6F1B2C3D-0000-4000-8000-000000000001"]
        #expect(AgentHook.input(environment: all, app: "com.apple.Terminal", tty: { "/dev/ttys009" }) == .muxy("1"))
        var rest = all
        rest["MUXY_SESSION_ID"] = nil
        #expect(AgentHook.input(environment: rest, app: nil) == .cmux("6F1B2C3D-0000"))
        rest["CMUX_SURFACE_ID"] = nil
        #expect(AgentHook.input(environment: rest, app: nil) == .wezterm(pane: "7", socket: wezSocket))
        // Of the rest the one the process tree is in is taken; none, the first.
        #expect(AgentHook.input(environment: rest, app: nil, hosted: { if case .kitty = $0 { true } else { false } }) == .kitty(window: "3", socket: kittySocket))
        #expect(AgentHook.input(environment: rest, app: nil, hosted: { _ in false }) == .wezterm(pane: "7", socket: wezSocket))
        // iTerm2 needs its app and a device; Terminal.app its app and a device.
        let iterm = ["ITERM_SESSION_ID": "w0t0p0:6F1B2C3D-0000-4000-8000-000000000001"]
        #expect(AgentHook.input(environment: iterm, app: TerminalScripts.itermID, tty: { "/dev/ttys004" }) == .iterm(tty: "/dev/ttys004"))
        #expect(AgentHook.input(environment: iterm, app: nil, tty: { "/dev/ttys004" }) == nil)
        #expect(AgentHook.input(environment: iterm, app: TerminalScripts.itermID, tty: { nil }) == nil)
        #expect(AgentHook.input(environment: [:], app: TerminalScripts.terminalID, tty: { "/dev/ttys003" }) == .terminalApp(tty: "/dev/ttys003"))
    }

    /// Both pass through the very function the hook's headers do, so the two can't drift apart.
    @Test func theHeadersAndTheEnvironmentGiveTheSameTarget() {
        let cases: [(headers: [String: String], environment: [String: String])] = [
            (["x-muxy": "42"], ["MUXY_SESSION_ID": "42"]),
            (["x-muxy": "4 2", "x-cmux": "6F1B2C3D-0000"], ["MUXY_SESSION_ID": "4 2", "CMUX_SURFACE_ID": "6F1B2C3D-0000"]),
            (["x-wezterm": "7", "x-wezterm-socket": wezSocket, "x-kitty": "3", "x-kitty-socket": kittySocket],
             ["WEZTERM_PANE": "7", "WEZTERM_UNIX_SOCKET": wezSocket, "KITTY_WINDOW_ID": "3", "KITTY_LISTEN_ON": kittySocket]),
            (["x-kitty": "3"], ["KITTY_WINDOW_ID": "3"]),
            (["x-mux": "1", "x-muxy": "42"], ["TMUX": "/tmp/x", "MUXY_SESSION_ID": "42"]),
            (["x-herdr": "1", "x-muxy": "42"], ["HERDR_PANE_ID": "p_1", "MUXY_SESSION_ID": "42"]),
        ]
        let table = ProcessTable { _ in .init(parent: 2, executable: "/usr/bin/claude", hasTTY: true, tty: "/dev/ttys009") }
        for (headers, environment) in cases {
            let fromHook = AgentHook.event(headers: headers.merging(["x-session": "s", "x-event": "Stop", "x-pid": "4321"]) { $1 }, processes: table)?.input
            #expect(fromHook == AgentHook.input(environment: environment, app: nil), "\(headers)")
        }
    }
}

/// Made-up environments by pid, that note which pids were read and on which thread.
private final class FakeEnvironments: @unchecked Sendable {
    private let lock = NSLock()
    private var variables: [Int32: [String: String]]
    private var reads: [Int32] = []
    private var onMain: [Bool] = []

    init(_ variables: [Int32: [String: String]] = [:]) { self.variables = variables }

    var pidsRead: [Int32] { lock.withLock { reads } }
    var ranOnMainThread: Bool { lock.withLock { onMain.contains(true) } }
    func set(_ pid: Int32, _ environment: [String: String]) { lock.withLock { variables[pid] = environment } }
    var environment: ProcessEnvironment {
        ProcessEnvironment { [self] pid in
            lock.withLock {
                reads.append(pid)
                onMain.append(Thread.isMainThread)
                return variables[pid]
            }
        }
    }
}

@MainActor
struct EnvironmentFallbackModelTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let clis = TerminalCLIs(muxy: URL(fileURLWithPath: "/m/muxy"), cmux: URL(fileURLWithPath: "/c/cmux"))
    private let muxyServer = "/Applications/Muxy.app/Contents/MacOS/muxy-server"
    private let cmuxApp = "/Applications/cmux.app/Contents/MacOS/cmux"

    /// Genuine sessions: claude 100 in Muxy, 110 in Muxy, 200 in cmux; claude 300 in neither (an unrelated shell).
    private var tree: [Int32: ProcessRecord] {
        let claude = "/Users/me/.local/share/claude/versions/2.1"
        return [
            100: .init(parent: 101, executable: claude, hasTTY: true), 101: .init(parent: 102, executable: "/bin/zsh", hasTTY: true),
            102: .init(parent: 1, executable: muxyServer, hasTTY: false),
            110: .init(parent: 101, executable: claude, hasTTY: true),
            200: .init(parent: 201, executable: claude, hasTTY: true), 201: .init(parent: 202, executable: "/bin/zsh", hasTTY: true),
            202: .init(parent: 1, executable: cmuxApp, hasTTY: false),
            300: .init(parent: 301, executable: claude, hasTTY: true), 301: .init(parent: 1, executable: "/bin/zsh", hasTTY: true),
        ]
    }

    private func agent(input: AgentInput? = nil, pid: Int32? = 100, app: String? = nil) -> AgentBoard.Agent {
        AgentBoard.Agent(state: .working, since: start, tool: "claude", app: app, input: input, pid: pid)
    }

    private func makeModel(_ board: AgentBoard, _ environments: FakeEnvironments) -> AgentsTabModel {
        let records = tree
        let check = AgentTargetCheck(processes: ProcessTable { records[$0] }, muxyList: { _ in "42\tname\tLive\ttrue\t/tmp\n7\tname\tLive\ttrue\t/tmp\n" })
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: AgentSender { _ in .sent }, clis: { clis }, targets: check, environments: environments.environment)
        model.fixedRecent = []
        return model
    }

    private func settle(_ model: AgentsTabModel, at now: Date? = nil) async {
        model.refresh(now: now ?? start)
        await eventually { !model.verifying }
    }

    private func row(_ model: AgentsTabModel, _ id: String = "a") throws -> AgentRow {
        try #require(model.rows.first { $0.id == "hooks:claude|\(id)" })
    }

    private func board(_ agents: [String: AgentBoard.Agent]) -> AgentBoard {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: agents, now: start)
        return board
    }

    @Test func aSessionTheHookNamedNothingForGetsItsTargetFromItsProcess() async throws {
        let environments = FakeEnvironments([100: ["MUXY_SESSION_ID": "42"], 200: ["CMUX_SURFACE_ID": "6F1B2C3D-0000"]])
        let model = makeModel(board(["a": agent(pid: 100), "b": agent(pid: 200)]), environments)
        await settle(model)
        let muxy = try row(model), cmux = try row(model, "b")
        #expect(muxy.input == .muxy("42") && muxy.offersInput && muxy.acceptsInput)
        #expect(cmux.input == .cmux("6F1B2C3D-0000") && cmux.offersInput)
        #expect(!environments.ranOnMainThread)
    }

    @Test func theHooksTargetWinsAndItsProcessIsNotRead() async throws {
        let environments = FakeEnvironments([100: ["MUXY_SESSION_ID": "7"], 200: ["MUXY_SESSION_ID": "7"]])
        let model = makeModel(board(["a": agent(input: .muxy("42"), pid: 100), "b": agent(input: .cmux("6F1B2C3D-0000"), pid: 200)]), environments)
        await settle(model)
        #expect(try row(model).input == .muxy("42") && row(model, "b").input == .cmux("6F1B2C3D-0000"))
        #expect(try row(model).offersInput && row(model, "b").offersInput)
        #expect(environments.pidsRead.isEmpty)
    }

    @Test func aTargetFromTheProcessIsVerifiedLikeTheHooks() async throws {
        // In Muxy's tree but not in its session list; in no terminal's tree at all; a Muxy id on a process under cmux.
        let environments = FakeEnvironments([100: ["MUXY_SESSION_ID": "99"], 300: ["MUXY_SESSION_ID": "42"], 200: ["MUXY_SESSION_ID": "42"]])
        let model = makeModel(board(["a": agent(pid: 100), "b": agent(pid: 300), "c": agent(pid: 200)]), environments)
        await settle(model)
        for id in ["a", "b", "c"] {
            let row = try row(model, id)
            #expect(row.input != nil && !row.offersInput && !row.acceptsInput, "\(id)")
        }
        #expect(try row(model, "a").input == .muxy("99"))
    }

    @Test func badValuesAMultiplexerAndHerdrGiveNoTarget() async throws {
        let environments = FakeEnvironments([
            100: ["MUXY_SESSION_ID": "4 2"], 110: ["MUXY_SESSION_ID": "42", "TMUX": "/tmp/tmux-501/default,1,0"],
            200: ["CMUX_SURFACE_ID": "6F1B2C3D-0000", "HERDR_PANE_ID": "p_1"], 300: [:],
        ])
        let model = makeModel(board(["a": agent(pid: 100), "b": agent(pid: 110), "c": agent(pid: 200), "d": agent(pid: 300), "e": agent(pid: 999)]), environments)
        await settle(model)
        for id in ["a", "b", "c", "d", "e"] {
            let row = try row(model, id)
            #expect(row.input == nil && !row.offersInput && !row.inputBlocked, "\(id)")
        }
    }

    @Test func aSessionWithoutAPidIsNeverLookedUp() async throws {
        let environments = FakeEnvironments([100: ["MUXY_SESSION_ID": "42"]])
        let model = makeModel(board(["a": agent(pid: nil)]), environments)
        await settle(model)
        #expect(try row(model).input == nil)
        #expect(environments.pidsRead.isEmpty)
    }

    @Test func eachPidIsReadOnceAndOnlyWhileItIsOnTheBoard() async throws {
        let environments = FakeEnvironments([100: ["MUXY_SESSION_ID": "42"], 110: ["MUXY_SESSION_ID": "7"]])
        let board = board(["a": agent(pid: 100), "b": agent(input: .cmux("6F1B2C3D-0000"), pid: 200)])
        let model = makeModel(board, environments)
        await settle(model)
        await settle(model)
        await settle(model, at: start.addingTimeInterval(60))
        #expect(environments.pidsRead == [100])
        #expect(try row(model).input == .muxy("42"))
        // A new session is read, the first still isn't.
        board.replace(source: "hooks:claude", with: ["a": agent(pid: 100), "b": agent(pid: 110)], now: start)
        await settle(model)
        #expect(environments.pidsRead == [100, 110])
        #expect(try row(model, "b").input == .muxy("7"))
        // Gone from the board it is forgotten, so a process that reuses the pid is read afresh.
        board.replace(source: "hooks:claude", with: ["b": agent(pid: 110)], now: start)
        await settle(model)
        board.replace(source: "hooks:claude", with: ["a": agent(pid: 100), "b": agent(pid: 110)], now: start)
        await settle(model)
        #expect(environments.pidsRead == [100, 110, 100])
    }

    @Test func aTargetTheHookNamesLaterTakesTheFallbacksPlace() async throws {
        let environments = FakeEnvironments([100: ["MUXY_SESSION_ID": "42"]])
        let board = board(["a": agent(pid: 100)])
        let model = makeModel(board, environments)
        await settle(model)
        #expect(try row(model).input == .muxy("42"))
        board.replace(source: "hooks:claude", with: ["a": agent(input: .muxy("7"), pid: 100)], now: start)
        await settle(model)
        #expect(try row(model).input == .muxy("7") && row(model).offersInput)
        // And a different process under the same session is not given the old process's target.
        board.replace(source: "hooks:claude", with: ["a": agent(pid: 110)], now: start)
        await settle(model)
        #expect(try row(model).input == nil)
        environments.set(110, ["MUXY_SESSION_ID": "7"])
        board.replace(source: "hooks:claude", with: ["a": agent(pid: 110)], now: start.addingTimeInterval(1))
        await settle(model, at: start.addingTimeInterval(1))
        #expect(try row(model).input == nil)  // 110 was read, found nothing, and an environment doesn't change
    }

    @Test func aTerminalAppSessionTheHookNamedNothingForIsToldByItsAppAndDevice() async throws {
        // Terminal.app: the hook sent X-App but the event had no device then (no pid); the device now comes from the process.
        var records = tree
        records[400] = .init(parent: 401, executable: "/Users/me/.local/share/claude/versions/2.1", hasTTY: true, tty: "/dev/ttys003")
        records[401] = .init(parent: 402, executable: "/bin/zsh", hasTTY: true)
        records[402] = .init(parent: 403, executable: "/usr/bin/login", hasTTY: true)
        records[403] = .init(parent: 1, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", hasTTY: false)
        let table = records
        let check = AgentTargetCheck(processes: ProcessTable { table[$0] }, muxyList: { _ in nil })
        let model = AgentsTabModel(board: board(["a": agent(pid: 400, app: TerminalScripts.terminalID)]), home: { URL(fileURLWithPath: "/nonexistent-home") },
                                   isConnected: { true }, scratch: [], sender: AgentSender { _ in .sent }, clis: { clis }, targets: check,
                                   environments: FakeEnvironments().environment)
        model.fixedRecent = []
        await settle(model)
        #expect(try row(model).input == .terminalApp(tty: "/dev/ttys003") && row(model).offersInput)
    }
}
