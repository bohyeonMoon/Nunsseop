import Foundation
import Testing
@testable import Nunsseop

// Terminal.app, iTerm2, WezTerm and kitty as places to type into and to resume in. Nothing here starts a terminal or sends an Apple Event
// to one: the process tables are made up, the Apple Event runner and the tools are stand-ins that record.

private let claudeExe = "/Users/me/.local/share/claude/versions/2.1"
private let terminalExe = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
private let itermServer = "/Applications/iTerm.app/Contents/MacOS/iTermServer-3.5.0"
private let weztermGUI = "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui"
private let kittyExe = "/Applications/kitty.app/Contents/MacOS/kitty"
private let socket = "unix:/tmp/kitty-4242"
private let wezSocket = "/Users/me/.local/share/wezterm/gui-sock-1200"

private func claude(parent: Int32, tty: String? = nil) -> ProcessRecord {
    .init(parent: parent, executable: claudeExe, hasTTY: true, tty: tty)
}

private func shell(parent: Int32) -> ProcessRecord { .init(parent: parent, executable: "/bin/zsh", hasTTY: true) }

/// Genuine sessions: Terminal (claude 1000 on ttys003), iTerm2 whose server outlived the app (1100 on ttys004), WezTerm (1200) and kitty (1300).
private let genuine: [Int32: ProcessRecord] = [
    1000: claude(parent: 1001, tty: "/dev/ttys003"), 1001: shell(parent: 1002),
    1002: .init(parent: 1003, executable: "/usr/bin/login", hasTTY: true), 1003: .init(parent: 1, executable: terminalExe, hasTTY: false),
    1100: claude(parent: 1101, tty: "/dev/ttys004"), 1101: shell(parent: 1102),
    1102: .init(parent: 1103, executable: "/usr/bin/login", hasTTY: true), 1103: .init(parent: 1, executable: itermServer, hasTTY: false),
    1200: claude(parent: 1201, tty: "/dev/ttys005"), 1201: shell(parent: 1202), 1202: .init(parent: 1, executable: weztermGUI, hasTTY: false),
    1300: claude(parent: 1301, tty: "/dev/ttys006"), 1301: shell(parent: 1302),
    1302: .init(parent: 1303, executable: "/usr/bin/login", hasTTY: true), 1303: .init(parent: 1, executable: kittyExe, hasTTY: false),
]

private func check(_ tree: [Int32: ProcessRecord] = genuine) -> AgentTargetCheck {
    AgentTargetCheck(processes: ProcessTable { tree[$0] }, muxyList: { _ in nil })
}

private let inputs: [(input: AgentInput, pid: Int32)] = [
    (.terminalApp(tty: "/dev/ttys003"), 1000), (.iterm(tty: "/dev/ttys004"), 1100),
    (.wezterm(pane: "7", socket: wezSocket), 1200), (.kitty(window: "3", socket: socket), 1300),
]

struct TerminalHeaderTests {
    @Test func paneAndWindowIdsAreUpToTenDigits() {
        #expect(AgentInput.numericID("0") == "0" && AgentInput.numericID("4294967295") == "4294967295")
        for bad in [nil, "", "12345678901", "1a", " 1", "1\n", "-1", "١", "$(id)", "1;id"] { #expect(AgentInput.numericID(bad) == nil, "\(bad ?? "nil")") }
    }

    @Test func kittysAddressIsAUnixSocketPathAndNothingElse() {
        #expect(AgentInput.kittySocket("unix:/tmp/kitty-4242") == "unix:/tmp/kitty-4242")
        #expect(AgentInput.kittySocket("unix:/private/tmp/my kitty") == nil)
        let bad: [String?] = [nil, "", "unix:", "unix:relative/path", "tcp:localhost:5000", "unix:@abstract", "unix:/tmp/../etc/x", "unix:/tmp/x\n",
                              "unix:/tmp/x;id", "unix:/tmp/$(id)", "unix:/tmp/`id`", "unix:/tmp/'x'", "/tmp/kitty", "unix:/" + String(repeating: "a", count: 101),
                              "unix:/tmp/é"]
        for value in bad { #expect(AgentInput.kittySocket(value) == nil, "\(value ?? "nil")") }
    }

    @Test func weztermsSocketIsAnAbsolutePathAndNothingElse() {
        #expect(AgentInput.weztermSocket(wezSocket) == wezSocket)
        let bad: [String?] = [nil, "", "gui-sock-1", "unix:/tmp/gui-sock-1", "/tmp/../etc/x", "/tmp/x\n", "/tmp/x;id", "/tmp/$(id)", "/tmp/`id`", "/tmp/'x'",
                              "/Users/my name/gui-sock-1", "/" + String(repeating: "a", count: 100), "/tmp/é"]
        for value in bad { #expect(AgentInput.weztermSocket(value) == nil, "\(value ?? "nil")") }
    }

    @Test func anITermSessionIdIsLettersDigitsColonsAndDashes() {
        #expect(AgentInput.itermSession("w0t0p0:6F1B2C3D-0000-4000-8000-000000000001") != nil)
        for bad in [nil, "", String(repeating: "a", count: 65), "w0t0p0 :x", "w0t0p0:x\n", "a;b", "$(id)", "a/b"] {
            #expect(AgentInput.itermSession(bad) == nil, "\(bad ?? "nil")")
        }
    }

    @Test func aTtyIsADevNodeOfTheTtysFamily() {
        #expect(AgentInput.ttyDevice("/dev/ttys003") == "/dev/ttys003" && AgentInput.ttyDevice("/dev/ttys1234") != nil)
        for bad in [nil, "", "/dev/ttys", "/dev/ttys1234567", "/dev/tty", "/dev/console", "/dev/ttys0a", "ttys003", "/dev/ttys003\n", "/dev/ttys003; id", "/tmp/dev/ttys003"] {
            #expect(AgentInput.ttyDevice(bad) == nil, "\(bad ?? "nil")")
        }
    }
}

struct TerminalHookEventTests {
    private let base = ["x-session": "s", "x-event": "Stop", "x-pid": "4321"]
    private let table = ProcessTable { $0 == 4321 ? claude(parent: 2, tty: "/dev/ttys009") : nil }

    private func input(_ extra: [String: String]) -> AgentInput? {
        AgentHook.event(headers: base.merging(extra) { $1 }, processes: table)?.input
    }

    @Test func weztermAndKittyAreToldByTheirOwnVariables() {
        #expect(input(["x-wezterm": "7", "x-wezterm-socket": wezSocket]) == .wezterm(pane: "7", socket: wezSocket))
        #expect(input(["x-kitty": "3", "x-kitty-socket": socket]) == .kitty(window: "3", socket: socket))
        // Without a socket kitty can't be reached from outside; a bad id or address is no target at all.
        #expect(input(["x-kitty": "3"]) == nil)
        #expect(input(["x-kitty": "3", "x-kitty-socket": "tcp:localhost:5000"]) == nil)
        #expect(input(["x-kitty": "x", "x-kitty-socket": socket]) == nil)
        #expect(input(["x-wezterm": "7;id", "x-wezterm-socket": wezSocket]) == nil)
    }

    @Test func aWeztermPaneIsNoTargetWithoutItsInstancesSocket() {
        #expect(input(["x-wezterm": "7"]) == nil)
        #expect(input(["x-wezterm": "7", "x-wezterm-socket": "unix:/tmp/x"]) == nil)
        #expect(input(["x-wezterm": "7", "x-wezterm-socket": "/tmp/../x"]) == nil)
        #expect(input(["x-wezterm-socket": wezSocket]) == nil)
    }

    /// A kitty started from a WezTerm shell has the variables of both; the process tree says which one it runs in.
    @Test func theTerminalTheProcessTreeIsInWinsOverThePriorityOfTheVariables() {
        let both = base.merging(["x-wezterm": "7", "x-wezterm-socket": wezSocket, "x-kitty": "3", "x-kitty-socket": socket]) { $1 }
        func event(in host: String) -> AgentInput? {
            let tree: [Int32: ProcessRecord] = [4321: claude(parent: 4322, tty: "/dev/ttys009"), 4322: shell(parent: 4323),
                                                4323: .init(parent: 1, executable: host, hasTTY: false)]
            return AgentHook.event(headers: both, processes: ProcessTable { tree[$0] })?.input
        }
        #expect(event(in: kittyExe) == .kitty(window: "3", socket: socket))
        #expect(event(in: weztermGUI) == .wezterm(pane: "7", socket: wezSocket))
        // In neither, the first stays (and its check refuses it later).
        #expect(event(in: "/usr/bin/other") == .wezterm(pane: "7", socket: wezSocket))
        // A candidate that fails keeps the next from being skipped only when the next passes: Terminal.app by app and device.
        let terminal = both.merging(["x-app": "com.apple.Terminal"]) { $1 }
        let tree: [Int32: ProcessRecord] = [4321: claude(parent: 4322, tty: "/dev/ttys009"), 4322: shell(parent: 4323),
                                            4323: .init(parent: 1, executable: terminalExe, hasTTY: false)]
        #expect(AgentHook.event(headers: terminal, processes: ProcessTable { tree[$0] })?.input == .terminalApp(tty: "/dev/ttys009"))
    }

    @Test func terminalAndITerm2AreToldByTheAppAndAddressedByTheDeviceOfTheSessionsProcess() {
        #expect(input(["x-app": "com.apple.Terminal"]) == .terminalApp(tty: "/dev/ttys009"))
        let session = "w0t0p0:6F1B2C3D-0000-4000-8000-000000000001"
        #expect(input(["x-app": "com.googlecode.iterm2", "x-iterm": session]) == .iterm(tty: "/dev/ttys009"))
        // iTerm2 needs its session id as well as its app; the app alone, or another app, is no target.
        #expect(input(["x-app": "com.googlecode.iterm2"]) == nil)
        #expect(input(["x-app": "com.googlecode.iterm2", "x-iterm": "a;b"]) == nil)
        #expect(input(["x-app": "com.mitchellh.ghostty", "x-iterm": session]) == nil)
        #expect(input([:]) == nil)
    }

    @Test func withoutAProcessOrADeviceTerminalAndITerm2HaveNoTarget() {
        let noPid = AgentHook.event(headers: ["x-session": "s", "x-event": "Stop", "x-app": "com.apple.Terminal"], processes: table)
        #expect(noPid != nil && noPid?.input == nil)
        let noDevice = ProcessTable { _ in .init(parent: 2, executable: claudeExe, hasTTY: true, tty: nil) }
        #expect(AgentHook.event(headers: base.merging(["x-app": "com.apple.Terminal"]) { $1 }, processes: noDevice)?.input == nil)
    }

    @Test func theNearerTerminalsVariablesComeFirst() {
        #expect(input(["x-muxy": "42", "x-wezterm": "7", "x-wezterm-socket": wezSocket, "x-app": "com.apple.Terminal"]) == .muxy("42"))
        #expect(input(["x-cmux": "6F1B2C3D-0000", "x-kitty": "3", "x-kitty-socket": socket]) == .cmux("6F1B2C3D-0000"))
        #expect(input(["x-wezterm": "7", "x-wezterm-socket": wezSocket, "x-kitty": "3", "x-kitty-socket": socket, "x-app": "com.apple.Terminal"]) == .wezterm(pane: "7", socket: wezSocket))
        // A bad id of the nearer one falls to the next.
        #expect(input(["x-wezterm": "7 7", "x-wezterm-socket": wezSocket, "x-app": "com.apple.Terminal"]) == .terminalApp(tty: "/dev/ttys009"))
    }

    @Test func multiplexersHerdrAndBackgroundSessionsHaveNoTargetFromTheseEither() {
        let all = ["x-wezterm": "7", "x-wezterm-socket": wezSocket, "x-app": "com.apple.Terminal"]
        #expect(input(all.merging(["x-mux": "1"]) { $1 }) == nil)
        #expect(input(all.merging(["x-herdr": "1"]) { $1 }) == nil)
        #expect(input(all.merging(["x-background": "1"]) { $1 }) == nil)
    }
}

struct TerminalVerificationTests {
    @Test func aGenuineSessionOfEachTerminalIsVerified() {
        for (input, pid) in inputs { #expect(check().verified(input, pid: pid, muxySessions: nil), "\(input)") }
    }

    @Test func iTerm2sServerCountsAsTheAppAndSoDoesTheApp() {
        var tree = genuine
        tree[1103] = .init(parent: 1, executable: "/Applications/iTerm.app/Contents/MacOS/iTerm2", hasTTY: false)
        #expect(check(tree).verified(.iterm(tty: "/dev/ttys004"), pid: 1100, muxySessions: nil))
        #expect(AgentTargetCheck.isITerm(itermServer) && AgentTargetCheck.isITerm("/Users/me/Applications/iTerm.app/Contents/MacOS/iTermServer-3.4.1"))
        #expect(!AgentTargetCheck.isITerm("/Applications/iTerm.app/Contents/MacOS/iTerm2-helper") && !AgentTargetCheck.isITerm("/Applications/Other.app/Contents/MacOS/iTerm2"))
        #expect(!AgentTargetCheck.isITerm("/tmp/iTermServer-3.5.0"))
    }

    @Test func iTerm2sServerInItsApplicationSupportFolderIsTheApp() {
        let support = "/Users/me/Library/Application Support/iTerm2/iTermServer-3.5.0"
        var tree = genuine
        tree[1103] = .init(parent: 1, executable: support, hasTTY: false)
        #expect(check(tree).verified(.iterm(tty: "/dev/ttys004"), pid: 1100, muxySessions: nil))
        #expect(AgentTargetCheck.isITerm(support))
        // A server of that name anywhere else is not iTerm2's, and a lookalike folder or a file that isn't a server neither.
        for path in ["/tmp/iTermServer-3.5.0", "/Users/me/Library/Application Support/Other/iTermServer-3.5.0",
                     "/Users/me/Library/Application Support/iTerm2/other-3.5.0", "/Users/me/Library/Application Support/iTerm2/scripts/run"] {
            #expect(!AgentTargetCheck.isITerm(path), Comment(rawValue: path))
        }
        // It is a terminal of its own for the others: a WezTerm pane whose chain meets it is not in WezTerm.
        tree[1202] = .init(parent: 1203, executable: "/bin/zsh", hasTTY: true)
        tree[1203] = .init(parent: 1, executable: support, hasTTY: false)
        #expect(!check(tree).hosted(.wezterm(pane: "7", socket: wezSocket), pid: 1200))
        tree[1203] = .init(parent: 1, executable: weztermGUI, hasTTY: false)
        #expect(check(tree).hosted(.wezterm(pane: "7", socket: wezSocket), pid: 1200))
    }

    @Test func theProcessMustBeOnTheDeviceTheTargetNames() {
        #expect(!check().hosted(.terminalApp(tty: "/dev/ttys099"), pid: 1000))
        #expect(!check().hosted(.iterm(tty: "/dev/ttys099"), pid: 1100))
        // A process with a terminal whose device isn't known never matches.
        var tree = genuine
        tree[1000] = claude(parent: 1001, tty: nil)
        #expect(!check(tree).hosted(.terminalApp(tty: "/dev/ttys003"), pid: 1000))
        // Another session's device, with this terminal's id, is not this session.
        #expect(!check().hosted(.terminalApp(tty: "/dev/ttys004"), pid: 1000))
    }

    @Test func aTerminalAppInTheWrongTerminalIsNotVerified() {
        // The id names Terminal but the chain meets iTerm2 first, and the other way round, and WezTerm's pane in a kitty window.
        #expect(!check().hosted(.terminalApp(tty: "/dev/ttys004"), pid: 1100))
        #expect(!check().hosted(.iterm(tty: "/dev/ttys003"), pid: 1000))
        #expect(!check().hosted(.wezterm(pane: "7", socket: wezSocket), pid: 1300))
        #expect(!check().hosted(.kitty(window: "3", socket: socket), pid: 1200))
        #expect(!check().hosted(.kitty(window: "3", socket: socket), pid: 1000))
    }

    @Test func anotherTerminalOrMultiplexerOnTheWayIsNotThisTerminal() {
        for path in ["/opt/homebrew/bin/tmux", "/Applications/Ghostty.app/Contents/MacOS/ghostty", "/Users/me/.local/bin/herdr", "/Applications/Muxy.app/Contents/MacOS/muxy-server"] {
            var tree = genuine
            tree[1001] = .init(parent: 1004, executable: "/bin/zsh", hasTTY: true)
            tree[1004] = .init(parent: 1002, executable: path, hasTTY: true)
            #expect(!check(tree).hosted(.terminalApp(tty: "/dev/ttys003"), pid: 1000), Comment(rawValue: path))
        }
    }

    @Test func noPidADeadPidOrNoControllingTerminalMeansNoTarget() {
        for (input, pid) in inputs {
            #expect(!check().hosted(input, pid: nil), "\(input)")
            #expect(!check().hosted(input, pid: 9999), "\(input)")
            var tree = genuine
            tree[pid] = .init(parent: tree[pid]!.parent, executable: claudeExe, hasTTY: false, tty: tree[pid]!.tty)
            #expect(!check(tree).hosted(input, pid: pid), "\(input)")
        }
    }

    @Test func aChildOfAnotherBoardSessionIsNotATarget() {
        var tree = genuine
        tree[1005] = claude(parent: 1000, tty: "/dev/ttys003")
        #expect(check(tree).hosted(.terminalApp(tty: "/dev/ttys003"), pid: 1005))
        #expect(!check(tree).hosted(.terminalApp(tty: "/dev/ttys003"), pid: 1005, others: [1000]))
        // The terminal itself being among "the others" is no child either: only what the chain meets before the host counts.
        #expect(check().hosted(.wezterm(pane: "7", socket: wezSocket), pid: 1200, others: [1200]))
    }

    @Test func theHostsAreRecognizedByTheirExecutables() {
        #expect(AgentTargetCheck.isTerminalApp(terminalExe) && !AgentTargetCheck.isTerminalApp("/Applications/Terminal.app/Contents/MacOS/Terminal"))
        #expect(!AgentTargetCheck.isTerminalApp("/usr/bin/login"))
        #expect(AgentTargetCheck.isWezTerm(weztermGUI) && AgentTargetCheck.isWezTerm("/Applications/WezTerm.app/Contents/MacOS/wezterm-mux-server"))
        #expect(!AgentTargetCheck.isWezTerm("/Applications/WezTerm.app/Contents/MacOS/wezterm") && !AgentTargetCheck.isWezTerm(kittyExe))
        #expect(AgentTargetCheck.isKitty(kittyExe) && AgentTargetCheck.isKitty("/opt/homebrew/bin/kitty") && !AgentTargetCheck.isKitty("/usr/bin/kitten"))
    }

    @Test func theLiveTableGivesTheDeviceOfAProcessInAPseudoTerminal() throws {
        // A child on a pseudo-terminal of its own prints its tty; the table must give the same for it. No real terminal is involved.
        let output = Pipe()
        let parent = try StandIn.python("""
        import pty
        pid, fd = pty.fork()
        if pid == 0:
            print(os.ttyname(0), flush=True)
            for _ in range(120):
                if os.getppid() == 1:
                    break
                time.sleep(0.5)
            os._exit(0)
        name = os.read(fd, 100).decode().strip()
        print(pid, name, flush=True)
        time.sleep(60)
        """, output: output)
        defer { parent.terminate() }
        var text = ""
        for _ in 0..<100 where !text.contains("\n") {
            let chunk = output.fileHandleForReading.availableData
            text += String(decoding: chunk, as: UTF8.self)
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        let parts = text.split(separator: " ")
        let pid = try #require(parts.first.flatMap { Int32($0) })
        let name = String(try #require(parts.last)).trimmingCharacters(in: .whitespacesAndNewlines)
        defer { kill(pid, SIGKILL) }
        let record = try #require(ProcessTable.live.lookup(pid))
        #expect(record.hasTTY && record.tty == name && AgentInput.ttyDevice(name) != nil, "\(name) \(record)")
        // This test's own process either has no terminal or has one; whatever it is, it is a device name or nil.
        let mine = try #require(ProcessTable.live.lookup(getpid()))
        #expect(mine.tty == nil || AgentInput.ttyDevice(mine.tty) != nil)
    }
}

/// Records every plan and every Apple Event call, and answers as told.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [[AgentStep]] = []
    var outcome: SendOutcome = .sent

    var recorded: [[AgentStep]] { lock.withLock { plans } }
    var sender: AgentSender {
        AgentSender { [self] steps in lock.withLock { plans.append(steps); return outcome } }
    }
}

private let hostile = "it's \"quoted\" \\ back\\slash $(touch pwn) `id` ; \\n -rf 日本語 🎉"

struct TerminalPlanTests {
    let clis = TerminalCLIs(muxy: nil, cmux: nil, wezterm: URL(fileURLWithPath: "/w/wezterm"), kitty: URL(fileURLWithPath: "/k/kitty"))

    @Test func terminalGetsTheTextAsAnArgumentOfAHandlerAndNeverInTheSource() throws {
        let steps = try #require(AgentSend.steps(.terminalApp(tty: "/dev/ttys003"), text: hostile, submit: true, clis: clis))
        guard case .script(let call)? = steps.first, steps.count == 1 else { Issue.record("not one script step: \(steps)"); return }
        #expect(call.bundleID == "com.apple.Terminal" && call.handler == "send_text" && call.expecting == "sent")
        #expect(call.arguments == ["/dev/ttys003", hostile])
        #expect(!call.source.contains(hostile) && !call.source.contains("pwn") && !call.source.contains("/dev/ttys003"))
        #expect(call.source.contains("on send_text(") && call.source.contains("tty of t is theTTY") && call.source.contains("do script theText in t"))
        // Sending needs the app to be open already.
        #expect(!call.launches)
    }

    @Test func terminalCannotTypeWithoutRunningSoDroppedPathsHaveNoPlan() {
        #expect(AgentSend.steps(.terminalApp(tty: "/dev/ttys003"), text: "/tmp/a.png ", submit: false, clis: clis) == nil)
        #expect(AgentInput.terminalApp(tty: "/dev/ttys003").takesFiles == false)
        for input in [AgentInput.iterm(tty: "/dev/ttys004"), .wezterm(pane: "7", socket: wezSocket), .kitty(window: "3", socket: socket), .muxy("1"), .cmux("6F1B2C3D-0000")] {
            #expect(input.takesFiles, "\(input)")
        }
    }

    @Test func iTerm2WritesTheTextWithOrWithoutTheNewline() throws {
        for submit in [true, false] {
            let steps = try #require(AgentSend.steps(.iterm(tty: "/dev/ttys004"), text: hostile, submit: submit, clis: clis))
            guard case .script(let call)? = steps.first, steps.count == 1 else { Issue.record("not one script step"); return }
            #expect(call.bundleID == "com.googlecode.iterm2" && call.arguments == ["/dev/ttys004", hostile, submit ? "1" : "0"])
            #expect(!call.source.contains(hostile) && !call.source.contains("pwn"))
            #expect(call.source.contains("write text theText newline false") && call.source.contains("if tty of s is theTTY"))
        }
    }

    @Test func noScriptRunsAShellOrAnotherScript() throws {
        let calls = [TerminalScripts.terminalSend(tty: "/dev/ttys003", text: "x"), TerminalScripts.itermSend(tty: "/dev/ttys004", text: "x", submit: true),
                     TerminalScripts.itermTab(command: "x"), TerminalScripts.ghosttyTab(cwd: "/", command: "x")]
        for call in calls {
            #expect(call.source.contains("application id \"\(call.bundleID)\""), Comment(rawValue: call.bundleID))
            for forbidden in ["do shell script", "run script", "osascript", "System Events", "keystroke", "key code"] {
                #expect(!call.source.contains(forbidden), Comment(rawValue: "\(call.bundleID) \(forbidden)"))
            }
            // The handler is the one named, and its parameters are as many as the arguments.
            let header = try #require(call.source.split(separator: "\n").first { $0.hasPrefix("on ") })
            #expect(header.hasPrefix("on \(call.handler)(") && header.split(separator: ",").count == call.arguments.count)
        }
    }

    @Test func weztermGetsTheTextTypedThenReturnAsArgv() throws {
        let cli = try #require(clis.wezterm)
        let steps = try #require(AgentSend.steps(.wezterm(pane: "7", socket: wezSocket), text: "-rf " + hostile, submit: true, clis: clis))
        let common = ["cli", "--no-auto-start", "send-text", "--pane-id", "7", "--no-paste", "--"]
        let variables = ["WEZTERM_UNIX_SOCKET": wezSocket]
        #expect(steps == [.runWith(cli, common + ["-rf " + hostile], variables: variables), .runWith(cli, common + ["\r"], variables: variables)])
        let drop = try #require(AgentSend.steps(.wezterm(pane: "7", socket: wezSocket), text: "/tmp/a.png ", submit: false, clis: clis))
        #expect(drop == [.runWith(cli, common + ["/tmp/a.png "], variables: variables)])
        #expect(AgentSend.steps(.wezterm(pane: "7", socket: wezSocket), text: "x", submit: true, clis: TerminalCLIs()) == nil)
    }

    @Test func kittyGetsTheTextOnStdinSoNoEscapeIsReadAndReturnAsAKey() throws {
        let cli = try #require(clis.kitty)
        let steps = try #require(AgentSend.steps(.kitty(window: "3", socket: socket), text: hostile, submit: true, clis: clis))
        #expect(steps == [.runInput(cli, ["@", "--to", socket, "send-text", "--match", "id:3", "--stdin"], stdin: hostile),
                          .run(cli, ["@", "--to", socket, "send-key", "--match", "id:3", "enter"])])
        let drop = try #require(AgentSend.steps(.kitty(window: "3", socket: socket), text: "/tmp/a.png ", submit: false, clis: clis))
        #expect(drop.count == 1)
        #expect(!steps.contains { if case .run(_, let arguments) = $0 { arguments.contains(hostile) } else { false } })
        #expect(AgentSend.steps(.kitty(window: "3", socket: socket), text: "x", submit: true, clis: TerminalCLIs()) == nil)
    }

    @Test func theToolsAreStartedWithoutTheVariablesThatNameNunsseopsOwnTerminal() {
        for name in ["WEZTERM_PANE", "KITTY_WINDOW_ID", "KITTY_LISTEN_ON"] { #expect(AgentSend.terminalVariables.contains(name), Comment(rawValue: name)) }
    }
}

struct TerminalExecutionTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-more-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A runner that answers `result` and records the calls.
    private final class Scripts: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [AppleScriptCall] = []
        var result: ScriptResult
        init(_ result: ScriptResult) { self.result = result }
        var calls: [AppleScriptCall] { lock.withLock { seen } }
        var runner: AppleScriptRunner { AppleScriptRunner { [self] call in lock.withLock { seen.append(call); return result } } }
    }

    private func call() -> AppleScriptCall { TerminalScripts.terminalSend(tty: "/dev/ttys003", text: hostile) }

    @Test func aScriptStepPassesOnlyWhenTheHandlerSaysItSent() {
        let sent = Scripts(.value("sent"))
        #expect(AgentSend.perform(.script(call()), scripts: sent.runner) == .sent)
        #expect(sent.calls == [call()])
        // No tab or session with that device: the handler says so and nothing was typed.
        #expect(AgentSend.perform(.script(call()), scripts: Scripts(.value("missing")).runner) == .failed)
        #expect(AgentSend.perform(.script(call()), scripts: Scripts(.failed).runner) == .failed)
    }

    @Test func aRefusedAppleEventIsReportedAsNotAllowedForThatApp() {
        #expect(AgentSend.perform(.script(call()), scripts: Scripts(.notAllowed).runner) == .notAllowed("com.apple.Terminal"))
        #expect(AgentSend.run([.script(call())], scripts: Scripts(.notAllowed).runner) == .notAllowed("com.apple.Terminal"))
        #expect(AppleScriptRunner.result(forError: -1743) == .notAllowed)
        for code in [0, -600, -1712, -2740, -10004] { #expect(AppleScriptRunner.result(forError: code) == .failed, "\(code)") }
        #expect(!AgentSend.execute(.script(call()), scripts: Scripts(.notAllowed).runner))
    }

    @Test func aPlanStopsAtTheFirstStepThatDoesNotPass() {
        let scripts = Scripts(.value("missing"))
        let tool = URL(fileURLWithPath: "/nonexistent/tool")
        #expect(AgentSend.run([.script(call()), .run(tool, [])], scripts: scripts.runner) == .failed)
        #expect(scripts.calls.count == 1)
    }

    /// The real runner, on a script that talks to no app: the handler is called by name with its arguments as text, whatever they hold, and
    /// what it returns comes back.
    @Test func theLiveRunnerCallsAHandlerWithTheArgumentsAsTextAndReturnsItsAnswer() {
        let source = "on echo(a, b)\n\treturn a & \"|\" & b\nend echo"
        let text = "it's \"q\" \\ back\\slash \\n $(touch pwn) `id` \u{1b}[31m 日本語 🎉"
        let call = AppleScriptCall(bundleID: "com.nunsseop.none", source: source, handler: "echo", arguments: [text, "x"], expecting: "", launches: true)
        #expect(AppleScriptRunner.live.run(call) == .value(text + "|x"))
        // A handler that isn't there, and a script that doesn't compile, fail without taking the process down.
        let missing = AppleScriptCall(bundleID: "com.nunsseop.none", source: source, handler: "nothing", arguments: [], expecting: "", launches: true)
        #expect(AppleScriptRunner.live.run(missing) == .failed)
        let broken = AppleScriptCall(bundleID: "com.nunsseop.none", source: "on echo(", handler: "echo", arguments: [], expecting: "", launches: true)
        #expect(AppleScriptRunner.live.run(broken) == .failed)
    }

    @Test func theLiveRunnerDoesNotStartAnAppThatIsntRunningForASend() {
        let call = AppleScriptCall(bundleID: "com.nunsseop.not-running-terminal", source: "on f()\nreturn \"x\"\nend f", handler: "f",
                                   arguments: [], expecting: "x", launches: false)
        #expect(AppleScriptRunner.live.run(call) == .failed)
    }

    @Test func weztermsToolGetsTheSocketOfTheSessionsInstanceNotNunsseops() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("tool")
        try StubTool.write("#!/bin/sh\necho \"[${WEZTERM_UNIX_SOCKET-unset}][${WEZTERM_PANE-unset}]\" > \"\(dir.path)/env\"\n", to: tool)
        let saved = ProcessInfo.processInfo.environment["WEZTERM_UNIX_SOCKET"]
        setenv("WEZTERM_UNIX_SOCKET", "/tmp/nunsseops-own", 1)
        setenv("WEZTERM_PANE", "9", 1)
        defer { if let saved { setenv("WEZTERM_UNIX_SOCKET", saved, 1) } else { unsetenv("WEZTERM_UNIX_SOCKET") }; unsetenv("WEZTERM_PANE") }
        #expect(AgentSend.terminalVariables.contains("WEZTERM_UNIX_SOCKET"))
        #expect(AgentSend.execute(.runWith(tool, ["cli"], variables: ["WEZTERM_UNIX_SOCKET": wezSocket])))
        #expect(try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8) == "[\(wezSocket)][unset]\n")
        // Without the variable named, Nunsseop's own does not leak through.
        #expect(AgentSend.execute(.run(tool, ["cli"])))
        #expect(try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8) == "[unset][unset]\n")
    }

    @Test func kittyStdinReachesTheToolAsItIsAndNoneOfNunsseopsTerminalVariablesDo() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("tool")
        try StubTool.write("#!/bin/sh\ncat > \"\(dir.path)/stdin\"\nfor a; do printf '%s\\n' \"$a\"; done > \"\(dir.path)/args\"\n"
                           + "echo \"[${WEZTERM_PANE-unset}][${KITTY_WINDOW_ID-unset}][${KITTY_LISTEN_ON-unset}]\" > \"\(dir.path)/env\"\n", to: tool)
        let names = ["WEZTERM_PANE", "KITTY_WINDOW_ID", "KITTY_LISTEN_ON"]
        let saved = names.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for name in names { setenv(name, "9", 1) }
        defer { for (name, value) in saved { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }

        let text = "line one\\n\\r $(touch pwn) 'q' \"d\" \u{1b}[31m"
        #expect(AgentSend.execute(.runInput(tool, ["@", "send-text", "--stdin"], stdin: text)))
        #expect(try String(contentsOf: dir.appendingPathComponent("stdin"), encoding: .utf8) == text)
        #expect(try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8) == "@\nsend-text\n--stdin\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8) == "[unset][unset][unset]\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwn").path))
        // A tool that ends without reading its input fails or passes by its status, and doesn't end Nunsseop with a broken pipe.
        let quiet = dir.appendingPathComponent("quiet")
        try StubTool.write("#!/bin/sh\nexit 0\n", to: quiet)
        _ = AgentSend.execute(.runInput(quiet, [], stdin: String(repeating: "x", count: 4000)))
        #expect(!AgentSend.execute(.runInput(dir.appendingPathComponent("missing"), [], stdin: "x")))
    }
}

@MainActor
struct TerminalRowTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let clis = TerminalCLIs(muxy: nil, cmux: nil, wezterm: URL(fileURLWithPath: "/w/wezterm"), kitty: URL(fileURLWithPath: "/k/kitty"))

    private func make(_ recorder: Recorder, _ input: AgentInput, pid: Int32) async -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": AgentBoard.Agent(state: .working, since: start, tool: "claude", input: input, pid: pid)], now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: recorder.sender, clis: { clis }, targets: check())
        model.noteDuration = eventDeadline
        model.fixedRecent = []
        model.refresh(now: start)
        await eventually { !model.verifying }
        return model
    }

    private func row(_ model: AgentsTabModel) throws -> AgentRow { try #require(model.rows.first) }

    @Test func eachTerminalsRowOffersInputOnceVerified() async throws {
        for (input, pid) in inputs {
            let model = await make(Recorder(), input, pid: pid)
            let row = try row(model)
            #expect(row.offersInput && row.acceptsInput, "\(input)")
        }
        // The same inputs with a pid that isn't in that terminal offer nothing.
        let wrong = await make(Recorder(), .wezterm(pane: "7", socket: wezSocket), pid: 1000)
        #expect(try !row(wrong).offersInput)
    }

    @Test func aMessageToTerminalGoesAsOneScriptStep() async throws {
        let recorder = Recorder()
        let model = await make(recorder, .terminalApp(tty: "/dev/ttys003"), pid: 1000)
        #expect(model.send(message: "run the tests", to: try row(model)))
        await eventually { !recorder.recorded.isEmpty }
        #expect(recorder.recorded == [[.script(TerminalScripts.terminalSend(tty: "/dev/ttys003", text: "run the tests"))]])
    }

    @Test func filesDroppedOnTerminalAreRefusedWithANoteAndNothingIsSent() async throws {
        let recorder = Recorder()
        let model = await make(recorder, .terminalApp(tty: "/dev/ttys003"), pid: 1000)
        let id = try row(model).id
        #expect(!model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: try row(model)))
        #expect(model.notes[id] == String(localized: "Terminal can't take text without running it"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.recorded.isEmpty)
        // Other terminals take the drop.
        let other = Recorder()
        let iterm = await make(other, .iterm(tty: "/dev/ttys004"), pid: 1100)
        #expect(iterm.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: try row(iterm)))
        await eventually { !other.recorded.isEmpty }
        #expect(other.recorded == [[.script(TerminalScripts.itermSend(tty: "/dev/ttys004", text: "/tmp/a.png ", submit: false))]])
    }

    @Test func aRefusalByMacOSLeavesTheAutomationNoteAndKeepsTheBubble() async throws {
        let recorder = Recorder()
        recorder.outcome = .notAllowed("com.googlecode.iterm2")
        let model = await make(recorder, .iterm(tty: "/dev/ttys004"), pid: 1100)
        let id = try row(model).id
        #expect(model.send(message: "hello", to: try row(model)))
        await eventually { model.notes[id] != nil }
        #expect(model.notes[id] == TerminalScripts.notAllowedNote("com.googlecode.iterm2"))
        #expect(model.notes[id]?.contains("iTerm2") == true && model.notes[id]?.contains("Automation") == true)
        await eventually { !model.verifying }
        // Still there to try again once it is allowed.
        #expect(try row(model).offersInput)
    }

    @Test func aFailureThatIsNotARefusalLeavesTheUsualNote() async throws {
        let recorder = Recorder()
        recorder.outcome = .failed
        let model = await make(recorder, .terminalApp(tty: "/dev/ttys003"), pid: 1000)
        let id = try row(model).id
        #expect(model.send(message: "hello", to: try row(model)))
        await eventually { model.notes[id] != nil }
        #expect(model.notes[id] == String(localized: "Couldn't send to this session"))
    }

    @Test func aResumeThatMacOSRefusedSaysWhereToAllowIt() async {
        let model = AgentsTabModel(board: AgentBoard(), home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [])
        model.noteDuration = eventDeadline
        #expect(model.resumeNote == nil)
        NotificationCenter.default.post(name: Resume.notAllowedNotification, object: nil, userInfo: ["bundleID": "com.mitchellh.ghostty"])
        await eventually { model.resumeNote != nil }
        #expect(model.resumeNote == TerminalScripts.notAllowedNote("com.mitchellh.ghostty") && model.resumeNote?.contains("Ghostty") == true)
    }

    @Test func theNewNotesAreTranslatedIntoEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for key in ["Allow Nunsseop to control %@ in System Settings › Privacy & Security › Automation", "Terminal can't take text without running it"] {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language) \(key)"))
            }
            #expect((table["Allow Nunsseop to control %@ in System Settings › Privacy & Security › Automation"] as? String)?.contains("%@") == true, Comment(rawValue: language))
            let plist = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/InfoPlist.strings").path))
            #expect((plist["NSAppleEventsUsageDescription"] as? String)?.isEmpty == false)
        }
    }

    @Test func theInfoPlistExplainsWhyNunsseopSendsAppleEvents() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist))
        let reason = try #require(info["NSAppleEventsUsageDescription"] as? String)
        for app in ["Terminal", "iTerm2", "Ghostty", "Music", "Spotify"] { #expect(reason.contains(app), Comment(rawValue: app)) }
    }

    /// Terminal.app is typed into, but its conversations are opened by a `.command` file, not in a tab by Apple Event: only iTerm2 and
    /// Ghostty are named for tabs. In each language the app is named once, with iTerm2, for typing.
    @Test func theConsentTextNamesTerminalOnlyForTypingAndTabsOnlyForITerm2AndGhostty() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let info = try #require(NSDictionary(contentsOf: resources.appendingPathComponent("Info.plist")))
        var texts = ["Info.plist": try #require(info["NSAppleEventsUsageDescription"] as? String)]
        for language in ["en", "de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/InfoPlist.strings").path), Comment(rawValue: language))
            texts[language] = try #require(table["NSAppleEventsUsageDescription"] as? String)
        }
        let word = try NSRegularExpression(pattern: "(?<![A-Za-z])Terminal(?![A-Za-z])")
        for (name, text) in texts {
            #expect(word.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 1, Comment(rawValue: name))
            let terminal = try #require(text.range(of: "Terminal"), Comment(rawValue: name))
            let iterm = try #require(text.range(of: "iTerm2"), Comment(rawValue: name))
            #expect(terminal.lowerBound < iterm.lowerBound, Comment(rawValue: name))
            #expect(text.ranges(of: "iTerm2").count == 2 && text.contains("Ghostty"), Comment(rawValue: name))
        }
        #expect(texts["en"]?.contains("new tabs of iTerm2 and Ghostty") == true)
    }
}

struct MoreTerminalsResumeTests {
    private let session = "5f0c2d1e-0000-4000-8000-000000000001"

    /// Every program and Apple Event call, in order; programs answer as `answers` says.
    private final class Log: @unchecked Sendable {
        var calls: [(program: String, arguments: [String])] = []
        var scripts: [AppleScriptCall] = []
        var answers: (String) -> Bool = { _ in true }
        var scriptResult: ScriptResult = .value("opened")
        var denials: [String] = []

        var launcher: Resume.Launcher {
            Resume.Launcher(run: { url, arguments in
                self.calls.append((url.lastPathComponent, arguments))
                return self.answers(url.lastPathComponent) ? "" : nil
            }, sleep: { _ in })
        }
        var runner: AppleScriptRunner {
            // Called on the calling thread only in these tests.
            AppleScriptRunner { [self] call in
                scripts.append(call)
                return scriptResult
            }
        }
    }

    private func folder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-resume-\(UUID().uuidString.prefix(8))/it's here").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func setup(_ log: Log, running: Set<String> = [], comesUp: Bool = false, kitty: String? = socket) -> Resume.Setup {
        Resume.Setup(installed: ResumeTerminal.allCases, ghostty: URL(fileURLWithPath: "/Applications/Ghostty.app"),
                     wezterm: URL(fileURLWithPath: "/Applications/WezTerm.app"), weztermCLI: URL(fileURLWithPath: "/Applications/WezTerm.app/Contents/MacOS/wezterm"),
                     kittyCLI: URL(fileURLWithPath: "/Applications/kitty.app/Contents/MacOS/kitty"), kittySocket: kitty, running: running,
                     isRunning: { _ in comesUp }, appleScript: log.runner, shell: "/bin/zsh", scripts: FileManager.default.temporaryDirectory)
    }

    private func conversation(_ cwd: String) -> RecentConversation {
        RecentConversation(kind: .claude, session: session, cwd: cwd, modified: .now)
    }

    private func line(_ cwd: String) -> String { "cd -- \(Resume.quote(cwd)) && exec claude --resume '\(session)'" }

    @Test func iTermOpensATabThroughTheHandlerWithTheLoginShellCommand() throws {
        let cwd = try folder()
        let log = Log()
        #expect(Resume.open(conversation(cwd), in: .iterm, setup: setup(log), launcher: log.launcher) == .iterm)
        let call = try #require(log.scripts.first)
        #expect(log.scripts.count == 1 && log.calls.isEmpty)
        #expect(call.bundleID == "com.googlecode.iterm2" && call.handler == "open_tab" && call.launches)
        #expect(call.arguments.count == 1)
        try expectResumeScript(call.arguments.first, runs: line(cwd))
        #expect(call.source.contains("create tab with default profile command theCommand") && call.source.contains("create window with default profile command theCommand"))
        #expect(!call.source.contains(session) && !call.source.contains("it's"))
    }

    @Test func iTermThatIsRefusedOrFailsFallsBackToTerminalAndTheRefusalIsReported() throws {
        let cwd = try folder()
        for (result, denied) in [(ScriptResult.notAllowed, true), (.failed, false), (.value("nope"), false)] {
            let log = Log()
            log.scriptResult = result
            var told: [String] = []
            let used = Resume.open(conversation(cwd), in: .iterm, setup: setup(log), launcher: log.launcher, denied: { told.append($0) })
            #expect(used == .terminal, "\(result)")
            #expect(told == (denied ? ["com.googlecode.iterm2"] : []), "\(result)")
            #expect(log.calls.map(\.program) == ["open"] && log.calls[0].arguments.first == "-b")
        }
    }

    @Test func ghosttyThatIsRunningGetsATabInTheFolderThroughTheHandler() throws {
        let cwd = try folder()
        let log = Log()
        #expect(Resume.open(conversation(cwd), in: .ghostty, setup: setup(log, running: ["com.mitchellh.ghostty"]), launcher: log.launcher) == .ghostty)
        let call = try #require(log.scripts.first)
        #expect(log.scripts.count == 1 && log.calls.isEmpty)
        #expect(call.bundleID == "com.mitchellh.ghostty" && call.arguments.count == 2 && call.arguments.first == cwd)
        try expectResumeScript(call.arguments.last, runs: line(cwd))
        #expect(call.source.contains("new tab in front window with configuration {initial working directory:theDir, command:theCommand}"))
        #expect(!call.source.contains("it's") && !call.source.contains(session))
    }

    @Test func ghosttyThatIsRefusedOrFailsFallsBackToANewWindowAsBefore() throws {
        let cwd = try folder()
        for result in [ScriptResult.notAllowed, .failed, .value("x")] {
            let log = Log()
            log.scriptResult = result
            var told: [String] = []
            let used = Resume.open(conversation(cwd), in: .ghostty, setup: setup(log, running: ["com.mitchellh.ghostty"]), launcher: log.launcher,
                                   denied: { told.append($0) })
            #expect(used == .ghostty, "\(result)")
            #expect(told == (result == .notAllowed ? ["com.mitchellh.ghostty"] : []))
            #expect(log.calls.count == 1 && log.calls[0].arguments.starts(with: ["-na", "/Applications/Ghostty.app", "--args", "--window-save-state=never"]))
        }
    }

    @Test func ghosttyThatIsNotRunningIsStartedWithoutItsFirstWindowAndOpensTheConversationByHandler() throws {
        let cwd = try folder()
        let log = Log()
        #expect(Resume.open(conversation(cwd), in: .ghostty, setup: setup(log, comesUp: true), launcher: log.launcher) == .ghostty)
        #expect(log.calls.count == 1 && log.calls[0].arguments == ["-a", "/Applications/Ghostty.app", "--args", "--initial-window=false", "--window-save-state=never"])
        let call = try #require(log.scripts.first)
        #expect(log.scripts.count == 1 && call.bundleID == "com.mitchellh.ghostty" && call.arguments.first == cwd)
        try expectResumeScript(call.arguments.last, runs: line(cwd))
    }

    @Test func ghosttyThatNeverComesUpFallsBackToItsCommandLine() throws {
        let cwd = try folder()
        let log = Log()
        #expect(Resume.open(conversation(cwd), in: .ghostty, setup: setup(log), launcher: log.launcher) == .ghostty)
        #expect(log.scripts.isEmpty && log.calls.count == 2 && log.calls[1].arguments.contains("--working-directory=\(cwd)"))
        try expectResumeScript(log.calls[1].arguments.last, runs: line(cwd))
    }

    @Test func weztermRunningGetsATabAsArgvAndComesForward() throws {
        let cwd = try folder()
        let log = Log()
        #expect(Resume.open(conversation(cwd), in: .wezterm, setup: setup(log, running: ["com.github.wez.wezterm"]), launcher: log.launcher) == .wezterm)
        #expect(log.calls.map(\.program) == ["wezterm", "open"])
        #expect(log.calls[0].arguments == ["cli", "--no-auto-start", "spawn", "--cwd", cwd, "--", "/bin/zsh", "-lc", line(cwd)])
        #expect(log.calls[1].arguments == ["-b", "com.github.wez.wezterm"])
        #expect(log.scripts.isEmpty)
    }

    @Test func weztermNotRunningIsStartedInTheFolder() throws {
        let cwd = try folder()
        let log = Log()
        #expect(Resume.open(conversation(cwd), in: .wezterm, setup: setup(log), launcher: log.launcher) == .wezterm)
        #expect(log.calls.map(\.program) == ["open"])
        #expect(log.calls[0].arguments == ["-na", "/Applications/WezTerm.app", "--args", "start", "--cwd", cwd, "--", "/bin/zsh", "-lc", line(cwd)])
    }

    @Test func weztermThatCannotBeToldFallsBackToTerminal() throws {
        let cwd = try folder()
        let log = Log()
        log.answers = { $0 != "wezterm" }
        #expect(Resume.open(conversation(cwd), in: .wezterm, setup: setup(log, running: ["com.github.wez.wezterm"]), launcher: log.launcher) == .terminal)
    }

    @Test func kittyNeedsTheSocketOfARunningKittyAndGetsATabThroughIt() throws {
        let cwd = try folder()
        let log = Log()
        #expect(Resume.open(conversation(cwd), in: .kitty, setup: setup(log), launcher: log.launcher) == .kitty)
        #expect(log.calls.map(\.program) == ["kitty", "open"])
        #expect(log.calls[0].arguments == ["@", "--to", socket, "launch", "--type=tab", "--cwd=\(cwd)", "/bin/zsh", "-lc", line(cwd)])
        #expect(log.calls[1].arguments == ["-b", "net.kovidgoyal.kitty"])
        // No socket, or a bad one, or a kitty that doesn't answer: Terminal takes it.
        for bad in [nil, "tcp:localhost:5000", "unix:/tmp/x;id"] {
            let other = Log()
            #expect(Resume.open(conversation(cwd), in: .kitty, setup: setup(other, kitty: bad), launcher: other.launcher) == .terminal, "\(bad ?? "nil")")
            #expect(!other.calls.contains { $0.program == "kitty" })
        }
        let silent = Log()
        silent.answers = { $0 != "kitty" }
        #expect(Resume.open(conversation(cwd), in: .kitty, setup: setup(silent), launcher: silent.launcher) == .terminal)
    }

    @Test func aHostileFolderStaysDataForEveryNewTerminal() throws {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-resume-\(UUID().uuidString.prefix(8))/$(touch pwn) `id` \"q\" 'a' ; x").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        for terminal in [ResumeTerminal.iterm, .wezterm, .kitty, .ghostty] {
            let log = Log()
            let running: Set<String> = [terminal.bundleID]
            _ = Resume.open(conversation(cwd), in: terminal, setup: setup(log, running: running), launcher: log.launcher)
            for call in log.scripts { #expect(!call.source.contains("pwn") && !call.source.contains(cwd), Comment(rawValue: terminal.rawValue)) }
            // Only a login shell ever parses the line, as one argument.
            for call in log.calls where call.program != "open" || call.arguments.contains("-lc") { #expect(call.arguments.filter { $0 == "-lc" }.count <= 1) }
        }
    }

    @Test func theKittySocketIsOnlyOfferedWhileItExists() throws {
        let path = "/tmp/nunsseop-k-\(UUID().uuidString.prefix(6))"
        #expect(!Kitty.socketExists("unix:" + path))
        try Data().write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(!Kitty.socketExists("unix:" + path), "a file is not a socket")
        try FileManager.default.removeItem(atPath: path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(bound == 0)
        #expect(Kitty.socketExists("unix:" + path))
    }

    @Test func aKittySessionsSocketIsKeptWhenItIsValidAndOnlyThen() throws {
        let name = "nunsseop-kitty-\(UUID().uuidString.prefix(8))"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Kitty.saved(in: defaults) == nil)
        // Other terminals' inputs, and none, leave it alone.
        for other in [AgentInput.wezterm(pane: "7", socket: wezSocket), .muxy("1"), .iterm(tty: "/dev/ttys004"), nil] { Kitty.remember(other, in: defaults) }
        #expect(Kitty.saved(in: defaults) == nil)
        Kitty.remember(.kitty(window: "3", socket: socket), in: defaults)
        #expect(Kitty.saved(in: defaults) == socket)
        // A newer session's socket replaces it.
        Kitty.remember(.kitty(window: "4", socket: "unix:/tmp/kitty-9"), in: defaults)
        #expect(Kitty.saved(in: defaults) == "unix:/tmp/kitty-9")
        // A value that doesn't pass the strict parse reads as none, even if something wrote it.
        defaults.set("unix:/tmp/../etc/x", forKey: "kittySocket")
        #expect(Kitty.saved(in: defaults) == nil)
    }

    @MainActor
    @Test func theEventsTheServerReceivesLeaveAKittySocketBehindAndReachTheBoard() throws {
        let name = "nunsseop-kitty-\(UUID().uuidString.prefix(8))"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let board = AgentBoard()
        let tools = ToolHooks(board: board, isOn: { true }, watchesHerdr: { false })
        tools.receive(AgentEvent(session: "k", action: .working, input: .kitty(window: "3", socket: socket)), defaults: defaults)
        #expect(Kitty.saved(in: defaults) == socket)
        #expect(board.counts == AgentBoard.Counts(working: 1))
        tools.receive(AgentEvent(session: "w", action: .working, input: .wezterm(pane: "7", socket: wezSocket)), defaults: UserDefaults(suiteName: name)!)
        #expect(Kitty.saved(in: defaults) == socket)
    }

    @Test func kittyIsOfferedOnlyWithItsAppItsToolAndALiveSocket() {
        let app = URL(fileURLWithPath: "/Applications/x.app")
        let cli = URL(fileURLWithPath: "/k/kitty")
        func offered(app hasApp: Bool = true, cli kittyCLI: URL? = cli, socket saved: String? = socket, exists: Bool = true, wezterm: Bool = false) -> [ResumeTerminal] {
            ResumeTerminal.installed(appURL: { hasApp && $0 != .wezterm ? app : nil }, weztermInstalled: wezterm, kittyCLI: kittyCLI, kittySocket: saved,
                                     socketExists: { _ in exists })
        }
        #expect(offered().contains(.kitty))
        #expect(!offered(app: false).contains(.kitty))
        #expect(!offered(cli: nil).contains(.kitty))
        #expect(!offered(socket: nil).contains(.kitty))
        #expect(!offered(exists: false).contains(.kitty))
        // Terminal is always there; WezTerm follows its own check, not the app lookup; the others follow their apps.
        #expect(offered(app: false) == [.terminal])
        #expect(offered(wezterm: true).contains(.wezterm) && !offered().contains(.wezterm))
        #expect(offered().contains(.ghostty) && offered().contains(.iterm) && offered().contains(.cmux))
    }

    @Test func weztermCountsAsInstalledWithOnlyItsCommandLineTool() {
        let app = URL(fileURLWithPath: "/Applications/WezTerm.app")
        #expect(WezTerm.isInstalled(app: app, isExecutable: { _ in false }))
        #expect(WezTerm.isInstalled(app: nil, isExecutable: { $0 == "/opt/homebrew/bin/wezterm" }))
        #expect(WezTerm.isInstalled(app: nil, isExecutable: { $0 == "/usr/local/bin/wezterm" }))
        #expect(!WezTerm.isInstalled(app: nil, isExecutable: { _ in false }))
        #expect(!WezTerm.isInstalled(app: nil, isExecutable: { $0 == "/tmp/wezterm" }))
    }

    @Test func theChoiceFallsBackToGhosttyThenTerminalWhenTheNewOnesAreMissing() {
        #expect(ResumeTerminal.effective(saved: "wezterm", installed: [.ghostty, .terminal]) == .ghostty)
        #expect(ResumeTerminal.effective(saved: "wezterm", installed: [.wezterm, .terminal]) == .wezterm)
        #expect(ResumeTerminal.effective(saved: "kitty", installed: [.terminal]) == .terminal)
        #expect(ResumeTerminal.terminal.bundleID == "com.apple.Terminal" && ResumeTerminal.iterm.bundleID == "com.googlecode.iterm2")
        #expect(ResumeTerminal.installed.contains(.terminal))
    }
}
