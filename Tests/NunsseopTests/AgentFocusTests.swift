import Foundation
import Testing
@testable import Nunsseop

// What a click on a session's row does. Nothing here starts a terminal, runs a terminal's tool or sends an Apple Event: the plans are
// compared as values, and the model gets a stand-in for the calls and the activation that records them.

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let claudeExe = "/Users/me/.local/share/claude/versions/2.1"
private let socket = "unix:/tmp/kitty-4242"
private let wezSocket = "/Users/me/.local/share/wezterm/gui-sock-1200"
private let uuid = "6F1B2C3D-0000-4000-8000-123456789ABC"
private let project = "AA2932BC-99A4-4172-845B-99E03F715C77"

private let clis = TerminalCLIs(muxy: URL(fileURLWithPath: "/m/muxy"), cmux: URL(fileURLWithPath: "/c/cmux"),
                                wezterm: URL(fileURLWithPath: "/w/wezterm"), kitty: URL(fileURLWithPath: "/k/kitty"))

private func entry(_ agent: AgentBoard.Agent) -> AgentBoard.Entry { AgentBoard.Entry(source: "hooks:claude", id: "a", agent: agent) }

private func agent(app: String? = nil, input: AgentInput? = nil, pid: Int32? = 100, pane: String? = nil, socket: String? = nil) -> AgentBoard.Agent {
    AgentBoard.Agent(state: .working, since: start, tool: "claude", app: app, pane: pane, socket: socket, input: input, pid: pid)
}

private func row(_ agent: AgentBoard.Agent, verified: Bool = true, hostApp: String? = nil) -> AgentRow {
    AgentRow(entry(agent), transcript: nil, inputVerified: verified, hostApp: hostApp)
}

struct AgentFocusStepsTests {
    @Test func eachTerminalIsFocusedThroughItsOwnToolWithExactArguments() throws {
        #expect(AgentFocus.steps(.muxy("42"), clis: clis, ghostty: nil) == [.muxyFocus(session: "42")])
        #expect(AgentFocus.steps(.cmux(uuid), clis: clis, ghostty: nil) == [.run(URL(fileURLWithPath: "/c/cmux"), ["focus-panel", "--panel", uuid])])
        // The instance is named by the socket, as for sending: pane ids mean nothing in another one.
        #expect(AgentFocus.steps(.wezterm(pane: "7", socket: wezSocket), clis: clis, ghostty: nil)
                == [.runWith(URL(fileURLWithPath: "/w/wezterm"), ["cli", "--no-auto-start", "activate-pane", "--pane-id", "7"], variables: ["WEZTERM_UNIX_SOCKET": wezSocket])])
        #expect(AgentFocus.steps(.kitty(window: "3", socket: socket), clis: clis, ghostty: nil)
                == [.run(URL(fileURLWithPath: "/k/kitty"), ["@", "--to", socket, "focus-window", "--match", "id:3"])])
        #expect(AgentFocus.steps(.terminalApp(tty: "/dev/ttys003"), clis: clis, ghostty: nil) == [.script(TerminalScripts.terminalFocus(tty: "/dev/ttys003"))])
        #expect(AgentFocus.steps(.iterm(tty: "/dev/ttys004"), clis: clis, ghostty: nil) == [.script(TerminalScripts.itermFocus(tty: "/dev/ttys004"))])
        // herdr has its own call (`Herdr.focus`), which is not a step.
        #expect(AgentFocus.steps(.herdr(pane: "p", socket: "/tmp/h.sock"), clis: clis, ghostty: nil) == nil)
    }

    @Test func aTerminalWhoseToolIsNotThereGetsNoSteps() {
        let none = TerminalCLIs()
        for input in [AgentInput.cmux(uuid), .wezterm(pane: "7", socket: wezSocket), .kitty(window: "3", socket: socket)] {
            #expect(AgentFocus.steps(input, clis: none, ghostty: nil) == nil, "\(input)")
        }
        // Muxy is gone to through its bridge extension or its folder, which need none of its tools.
        #expect(AgentFocus.steps(.muxy("42"), clis: none, ghostty: nil) == [.muxyFocus(session: "42")])
        // Terminal.app, iTerm2 and Ghostty need no tool but their own Apple Events.
        #expect(AgentFocus.steps(.terminalApp(tty: "/dev/ttys003"), clis: none, ghostty: nil) != nil)
    }

    @Test func ghosttyIsFocusedByTheTabTheSendResolvedAndWithTheSameChecks() throws {
        let pick = GhosttyPick(terminal: "T-1", usesName: true)
        let steps = try #require(AgentFocus.steps(.ghostty(cwd: "/Users/me/proj/", name: "fix the login"), clis: clis, ghostty: pick))
        guard case .script(let call)? = steps.first, steps.count == 1 else { Issue.record("not one script step"); return }
        #expect(call.bundleID == "com.mitchellh.ghostty" && call.handler == "focus_terminal" && call.expecting == "ok" && !call.launches)
        // The same arguments as a send to that tab: id, accepted folders, name, whether the name told the tabs apart.
        let send = try #require(AgentSend.steps(.ghostty(cwd: "/Users/me/proj/", name: "fix the login"), text: "x", submit: false, clis: clis, ghostty: pick))
        guard case .script(let sending)? = send.first else { Issue.record("not a script"); return }
        #expect(call.arguments == Array(sending.arguments.prefix(4)) && call.arguments == ["T-1", "/Users/me/proj\n/Users/me/proj/", "fix the login", "1"])
        // A name too short to look for is not passed, nor required.
        let short = try #require(AgentFocus.steps(.ghostty(cwd: "/Users/me/proj", name: "abc"), clis: clis, ghostty: pick))
        guard case .script(let shortCall)? = short.first else { Issue.record("not a script"); return }
        #expect(shortCall.arguments[2] == "" && shortCall.arguments[3] == "0")
        // No tab picked (or a folder that is no folder): nothing is focused.
        #expect(AgentFocus.steps(.ghostty(cwd: "/Users/me/proj", name: nil), clis: clis, ghostty: nil) == nil)
        #expect(AgentFocus.steps(.ghostty(cwd: "relative", name: nil), clis: clis, ghostty: pick) == nil)
    }

    @Test func theGhosttyFocusScriptFindsTheTabAgainLikeTheSendScriptAndTypesNothing() {
        let focus = TerminalScripts.ghosttyFocus(terminal: "A", folders: ["/p"], name: "", needsName: false).source
        let send = TerminalScripts.ghosttySend(terminal: "A", folders: ["/p"], name: "", needsName: false, text: "x", submit: true).source
        // Everything from the listing of the terminals to the checks is one text in both.
        func finder(_ source: String) -> [Substring] {
            let lines = source.split(separator: "\n")
            let begin = lines.firstIndex { $0.contains("set acceptedFolders") }!, end = lines.firstIndex { $0.contains("if not foundNamed and elsewhereNamed > 0") }!
            return Array(lines[begin...end])
        }
        #expect(finder(focus) == finder(send))
        #expect(focus.contains("return \"gone\"") && focus.contains("return \"ambiguous\"") && focus.contains("focus found") && focus.contains("with timeout of 5 seconds"))
        #expect(!focus.contains("input text") && !focus.contains("send key"))
    }

    @Test func noFocusScriptRunsAShellOrTakesAnythingInItsSource() throws {
        let hostile = "/dev/ttys003\" & (do shell script \"id\") & \""
        let calls = [TerminalScripts.terminalFocus(tty: hostile), TerminalScripts.itermFocus(tty: hostile),
                     TerminalScripts.ghosttyFocus(terminal: hostile, folders: [hostile], name: hostile, needsName: true)]
        for call in calls {
            #expect(call.source.contains("application id \"\(call.bundleID)\"") && !call.source.contains("pwn") && !call.source.contains("shell script \"id\""))
            for forbidden in ["do shell script", "run script", "osascript", "System Events", "keystroke", "key code"] {
                #expect(!call.source.contains(forbidden), Comment(rawValue: "\(call.bundleID) \(forbidden)"))
            }
            let header = try #require(call.source.split(separator: "\n").first { $0.hasPrefix("on \(call.handler)(") })
            #expect(header.split(separator: ",").count == call.arguments.count && !call.launches)
        }
        // Terminal and iTerm2 pick the tab by device, select it and raise it; neither types.
        let terminal = TerminalScripts.terminalFocus(tty: "/dev/ttys003")
        #expect(terminal.handler == "focus_tab" && terminal.arguments == ["/dev/ttys003"] && terminal.expecting == "focused")
        #expect(terminal.source.contains("if tty of t is theTTY") && terminal.source.contains("set selected of t to true")
                && terminal.source.contains("set index of w to 1") && terminal.source.contains("set miniaturized of w to false") && terminal.source.contains("activate"))
        #expect(!terminal.source.contains("do script"))
        let iterm = TerminalScripts.itermFocus(tty: "/dev/ttys004")
        #expect(iterm.handler == "focus_session" && iterm.arguments == ["/dev/ttys004"] && iterm.expecting == "focused")
        #expect(iterm.source.contains("if tty of s is theTTY") && iterm.source.contains("tell w to select") && iterm.source.contains("tell t to select")
                && iterm.source.contains("tell s to select") && iterm.source.contains("activate"))
        #expect(!iterm.source.contains("write text"))
    }

    @Test func aFocusScriptPassesOnlyWhenTheHandlerSaysItFocusedAndAsksTheAppNothingElse() {
        func run(_ call: AppleScriptCall, answering result: ScriptResult) -> (SendOutcome, [AppleScriptCall]) {
            let seen = Locked<[AppleScriptCall]>([])
            let outcome = AgentSend.perform(.script(call), scripts: AppleScriptRunner { call in seen.update { $0.append(call) }; return result })
            return (outcome, seen.value)
        }
        let terminal = TerminalScripts.terminalFocus(tty: "/dev/ttys003"), ghostty = TerminalScripts.ghosttyFocus(terminal: "A", folders: ["/p"], name: "", needsName: false)
        let focused = run(terminal, answering: .value("focused"))
        #expect(focused.0 == .sent && focused.1 == [terminal])
        // No such tab, or a Ghostty tab that is gone or has company: nothing was focused.
        #expect(run(terminal, answering: .value("missing")).0 == .failed && run(ghostty, answering: .value("gone")).0 == .failed)
        #expect(run(ghostty, answering: .value("ambiguous")).0 == .failed && run(ghostty, answering: .value("ok")).0 == .sent)
        #expect(run(terminal, answering: .notAllowed).0 == .notAllowed("com.apple.Terminal") && run(terminal, answering: .failed).0 == .failed)
    }

    @Test func eachTerminalNamesItsApp() {
        let expected: [(AgentInput, String?)] = [
            (.muxy("1"), "com.muxy.app"), (.cmux(uuid), "com.cmuxterm.app"), (.herdr(pane: "p", socket: "/s"), nil),
            (.terminalApp(tty: "/dev/ttys001"), "com.apple.Terminal"), (.iterm(tty: "/dev/ttys001"), "com.googlecode.iterm2"),
            (.wezterm(pane: "1", socket: wezSocket), "com.github.wez.wezterm"), (.kitty(window: "1", socket: socket), "net.kovidgoyal.kitty"),
            (.ghostty(cwd: "/p", name: nil), "com.mitchellh.ghostty"),
        ]
        for (input, app) in expected { #expect(AgentFocus.bundleID(of: input) == app, "\(input)") }
    }
}

struct AgentFocusPlanTests {
    private let pick = GhosttyPick(terminal: "T1", usesName: false)

    @Test func aVerifiedTerminalIsGoneToByTheSessionsOwnTabThenItsAppComesForward() {
        let verified = row(agent(app: "com.apple.Terminal", input: .iterm(tty: "/dev/ttys004")))
        #expect(AgentFocus.plan(for: verified, clis: clis) == .terminal([.script(TerminalScripts.itermFocus(tty: "/dev/ttys004"))], app: "com.googlecode.iterm2"))
        // The app is the terminal's, not the hook's word for it.
        let weztermRow = row(agent(app: "com.apple.Terminal", input: .wezterm(pane: "7", socket: wezSocket)))
        guard case .terminal(_, let app) = AgentFocus.plan(for: weztermRow, clis: clis) else { Issue.record("not a terminal plan"); return }
        #expect(app == "com.github.wez.wezterm")
        let ghostty = row(agent(input: .ghostty(cwd: "/Users/me/proj", name: nil)))
        guard case .terminal(let steps, "com.mitchellh.ghostty") = AgentFocus.plan(for: ghostty, clis: clis, ghostty: pick), steps.count == 1 else {
            Issue.record("not a Ghostty plan"); return
        }
    }

    @Test func aTerminalThatWasOnlyGuessedAtIsNeverFocusedOnlyItsAppIsBroughtForward() {
        let guess = row(agent(app: "com.apple.Terminal", input: .terminalApp(tty: "/dev/ttys003")), verified: false)
        #expect(!guess.offersInput && AgentFocus.plan(for: guess, clis: clis) == .app("com.apple.Terminal"))
        // Without an app named by the hook, the app found above the process.
        let found = row(agent(input: .kitty(window: "3", socket: socket)), verified: false, hostApp: "net.kovidgoyal.kitty")
        #expect(AgentFocus.plan(for: found, clis: clis) == .app("net.kovidgoyal.kitty"))
        // Nothing is known: a click does nothing, and the row says so.
        let unknown = row(agent(input: .muxy("42")), verified: false)
        #expect(AgentFocus.plan(for: unknown, clis: clis) == .nothing && !unknown.focusable)
    }

    @Test func theFallbackOrderIsTheVerifiedTabThenTheHooksAppThenTheAppAboveTheProcessThenNothing() {
        #expect(AgentFocus.plan(for: row(agent(app: "com.hook.App"), hostApp: "com.process.App"), clis: clis) == .app("com.hook.App"))
        #expect(AgentFocus.plan(for: row(agent(), hostApp: "com.process.App"), clis: clis) == .app("com.process.App"))
        // A name of an app folder is no bundle id, which nothing can be brought forward by.
        let named = row(agent(), hostApp: "Some App")
        #expect(AgentFocus.plan(for: named, clis: clis) == .nothing && !named.focusable && named.target == nil)
        let bare = row(agent())
        #expect(AgentFocus.plan(for: bare, clis: clis) == .nothing && !bare.focusable)
        #expect(row(agent(), hostApp: "com.process.App").focusable)
    }

    @Test func aVerifiedRowWhoseTabWasNotPickedOnlyActivatesItsApp() {
        let ghostty = row(agent(input: .ghostty(cwd: "/Users/me/proj", name: nil)))
        #expect(AgentFocus.plan(for: ghostty, clis: clis, ghostty: nil) == .app("com.mitchellh.ghostty"))
    }

    @Test func aHerdrPaneIsFocusedByHerdrWhateverElseTheRowHolds() {
        let pane = row(agent(app: "com.apple.Terminal", input: .herdr(pane: "w1:p2", socket: "/tmp/h.sock"), pane: "w1:p2", socket: "/tmp/h.sock"), verified: false)
        #expect(AgentFocus.plan(for: pane, clis: clis) == .herdr(pane: "w1:p2", socket: "/tmp/h.sock") && pane.focusable)
    }

    @Test func aRowIsClickableWhenSomethingIsToBeGoneTo() {
        #expect(row(agent(input: .cmux(uuid))).focusable)
        #expect(row(agent(app: "com.apple.Terminal"), verified: false).focusable)
        #expect(!row(agent(input: .cmux(uuid)), verified: false).focusable)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// What the stand-in did, in order, and on which thread.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    private var plans: [[AgentStep]] = []
    private var threads: [String: Bool] = [:]
    var outcome: SendOutcome = .sent

    var log: [String] { lock.withLock { all } }
    var steps: [[AgentStep]] { lock.withLock { plans } }
    func onMain(_ event: String) -> Bool? { lock.withLock { threads[event] } }

    private func record(_ event: String) {
        lock.withLock { all.append(event); threads[event] = Thread.isMainThread }
    }

    var focuser: AgentFocuser {
        AgentFocuser(run: { [self] steps in
            record("run")
            return lock.withLock { plans.append(steps); return outcome }
        }, activate: { [self] app in record("activate:\(app)") }, herdr: { [self] pane, _ in record("herdr:\(pane)") })
    }
}

/// A process table that can change while a test runs.
private final class Tree: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Int32: ProcessRecord]
    init(_ records: [Int32: ProcessRecord]) { self.records = records }
    var table: ProcessTable { ProcessTable { [self] pid in lock.withLock { records[pid] } } }
    func set(_ pid: Int32, _ record: ProcessRecord?) { lock.withLock { records[pid] = record } }
}

@MainActor
struct AgentFocusModelTests {
    /// 100 in Muxy, 200 in Terminal.app on ttys003, 300 under an app that has no input API and is installed (Calculator stands in), 400
    /// under one that is not installed (its bundle can't be read, so only its folder's name is known).
    private func tree() -> Tree {
        Tree([
            100: .init(parent: 101, executable: claudeExe, hasTTY: true), 101: .init(parent: 102, executable: "/bin/zsh", hasTTY: true),
            102: .init(parent: 1, executable: "/Applications/Muxy.app/Contents/MacOS/muxy-server", hasTTY: false),
            200: .init(parent: 201, executable: claudeExe, hasTTY: true, tty: "/dev/ttys003"), 201: .init(parent: 202, executable: "/bin/zsh", hasTTY: true),
            202: .init(parent: 203, executable: "/usr/bin/login", hasTTY: true),
            203: .init(parent: 1, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", hasTTY: false),
            300: .init(parent: 301, executable: claudeExe, hasTTY: true), 301: .init(parent: 302, executable: "/bin/zsh", hasTTY: true),
            302: .init(parent: 1, executable: "/System/Applications/Calculator.app/Contents/MacOS/Calculator", hasTTY: false),
            400: .init(parent: 401, executable: claudeExe, hasTTY: true), 401: .init(parent: 402, executable: "/bin/zsh", hasTTY: true),
            402: .init(parent: 1, executable: "/Applications/NoSuchTerm.app/Contents/MacOS/nosuch", hasTTY: false),
        ])
    }

    private func make(_ agents: [String: AgentBoard.Agent], tree: Tree, calls: Calls, source: String = "hooks:claude", scripts: AppleScriptRunner = .live,
                      environments: ProcessEnvironment = .live) async -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: source, with: agents, now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: AgentSender { _ in .failed }, clis: { clis },
                                   targets: AgentTargetCheck(processes: tree.table, muxyList: { _ in "42\t\(project)\tLive\ttrue\t/tmp\n" }),
                                   environments: environments, scripts: scripts, focuser: calls.focuser)
        model.noteDuration = eventDeadline
        model.fixedRecent = []
        model.refresh(now: start)
        await eventually { !model.verifying }
        return model
    }

    private func row(_ model: AgentsTabModel, _ id: String = "a") throws -> AgentRow {
        try #require(model.rows.first { $0.id.hasSuffix("|\(id)") })
    }

    private func claude(_ input: AgentInput?, pid: Int32?, app: String? = nil) -> AgentBoard.Agent {
        AgentBoard.Agent(state: .working, since: start, tool: "claude", app: app, input: input, pid: pid)
    }

    @Test func aVerifiedSessionsTabIsFocusedOffTheMainThreadThenItsAppIsActivatedOnIt() async throws {
        let calls = Calls()
        let model = await make(["a": claude(.terminalApp(tty: "/dev/ttys003"), pid: 200, app: "com.apple.Terminal")], tree: tree(), calls: calls)
        model.focus(try row(model))
        await eventually { calls.log.count == 2 }
        #expect(calls.log == ["run", "activate:com.apple.Terminal"])
        #expect(calls.steps == [[.script(TerminalScripts.terminalFocus(tty: "/dev/ttys003"))]])
        #expect(calls.onMain("run") == false && calls.onMain("activate:com.apple.Terminal") == true)
        #expect(model.notes.isEmpty)
    }

    @Test func aMuxySessionGoesToItsProjectAndMuxyComesForward() async throws {
        let calls = Calls()
        let model = await make(["a": claude(.muxy("42"), pid: 100)], tree: tree(), calls: calls)
        model.focus(try row(model))
        await eventually { calls.log.count == 2 }
        #expect(calls.steps == [[.muxyFocus(session: "42")]])
        #expect(calls.log == ["run", "activate:com.muxy.app"])
    }

    @Test func aSessionWhoseTerminalWasNotVerifiedOnlyActivatesItsApp() async throws {
        // The hook named Terminal and a device, but the process is not in it: the click may not select a tab of Terminal.
        let calls = Calls()
        let model = await make(["a": claude(.terminalApp(tty: "/dev/ttys003"), pid: 300, app: "com.apple.Terminal")], tree: tree(), calls: calls)
        #expect(try !row(model).offersInput)
        model.focus(try row(model))
        await eventually { !calls.log.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.log == ["activate:com.apple.Terminal"] && calls.steps.isEmpty)
    }

    @Test func aSessionWithoutAnAppOrATerminalFallsBackToTheAppAboveItsProcessElseNothing() async throws {
        let calls = Calls()
        let model = await make(["a": claude(nil, pid: 300), "b": claude(nil, pid: nil), "c": claude(nil, pid: 400)], tree: tree(), calls: calls)
        // An installed app with no input API is found above the process by its bundle id, and a click brings it forward.
        let above = try row(model)
        #expect(above.input == nil && above.target == .app("com.apple.calculator") && above.focusable)
        model.focus(above)
        await eventually { !calls.log.isEmpty }
        #expect(calls.log == ["activate:com.apple.calculator"] && calls.steps.isEmpty)
        // No process, or an app that is only a folder's name: nothing to go to, and the row does not look clickable.
        for id in ["b", "c"] {
            let none = try row(model, id)
            #expect(!none.focusable && none.target == nil, Comment(rawValue: id))
            model.focus(none)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.log == ["activate:com.apple.calculator"])
    }

    @Test func theTerminalIsLookedAtAgainWhenClickedAndNotFocusedIfTheSessionIsNoLongerIn() async throws {
        let calls = Calls()
        let processes = tree()
        let model = await make(["a": claude(.terminalApp(tty: "/dev/ttys003"), pid: 200)], tree: processes, calls: calls)
        let drawn = try row(model)
        #expect(drawn.offersInput)
        // The session's shell moved to another terminal after the row was drawn.
        processes.set(203, .init(parent: 1, executable: "/System/Applications/Calculator.app/Contents/MacOS/Calculator", hasTTY: false))
        model.focus(drawn)
        await eventually { !calls.log.isEmpty }
        #expect(calls.log == ["activate:com.apple.Terminal"] && calls.steps.isEmpty)
        // And it is checked again, so the row stops offering the tab.
        await eventually { !model.verifying }
        await eventually { (try? row(model).offersInput) == false }
        #expect(try !row(model).offersInput)
    }

    @Test func aRefusalByMacOSLeavesTheAutomationNoteAndStillBringsTheAppForward() async throws {
        let calls = Calls()
        calls.outcome = .notAllowed("com.apple.Terminal")
        let model = await make(["a": claude(.terminalApp(tty: "/dev/ttys003"), pid: 200)], tree: tree(), calls: calls)
        let id = try row(model).id
        model.focus(try row(model))
        await eventually { model.notes[id] != nil }
        #expect(model.notes[id] == TerminalScripts.notAllowedNote("com.apple.Terminal") && model.notes[id]?.contains("Automation") == true)
        #expect(calls.log == ["run", "activate:com.apple.Terminal"])
        // The target stays: allowing it later makes the next click work.
        await eventually { !model.verifying }
        #expect(try row(model).offersInput)
    }

    @Test func aFocusThatFailedBringsTheAppForwardAndLeavesNoNote() async throws {
        let calls = Calls()
        calls.outcome = .failed
        let model = await make(["a": claude(.terminalApp(tty: "/dev/ttys003"), pid: 200)], tree: tree(), calls: calls)
        model.focus(try row(model))
        await eventually { calls.log.count == 2 }
        #expect(calls.log == ["run", "activate:com.apple.Terminal"] && model.notes.isEmpty)
    }

    @Test func aHerdrPaneIsFocusedThroughHerdr() async throws {
        let calls = Calls()
        let model = await make(["w1:p2": AgentBoard.Agent(state: .working, since: start, tool: "claude", pane: "w1:p2", socket: "/tmp/h.sock",
                                                          input: .herdr(pane: "w1:p2", socket: "/tmp/h.sock"))],
                               tree: tree(), calls: calls, source: "herdr:/tmp/h.sock")
        model.focus(try row(model, "w1:p2"))
        #expect(calls.log == ["herdr:w1:p2"] && calls.steps.isEmpty)
    }

    @Test func aRowThatIsGoneIsNotFocused() async throws {
        let calls = Calls()
        let model = await make(["a": claude(.terminalApp(tty: "/dev/ttys003"), pid: 200)], tree: tree(), calls: calls)
        let drawn = try row(model)
        let empty = AgentBoard()
        let later = AgentsTabModel(board: empty, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [], focuser: calls.focuser)
        later.noteDuration = eventDeadline
        later.focus(drawn)
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.log.isEmpty)
    }

    @Test func aGhosttyRowIsFocusedByTheTabPickedForItFoundAgainByTheScript() async throws {
        let calls = Calls()
        let login = ProcessRecord(parent: 11, executable: "/usr/bin/login", hasTTY: true)
        let processes = Tree([
            100: .init(parent: 101, executable: claudeExe, hasTTY: true), 101: .init(parent: 10, executable: "/bin/zsh", hasTTY: true),
            10: login, 11: .init(parent: 1, executable: "/Applications/Ghostty.app/Contents/MacOS/ghostty", hasTTY: false),
        ])
        // Ghostty lists one tab in the session's folder, with a Claude title.
        let listing = "T1\u{1F}/Users/me/proj\u{1F}✳ Claude Code\u{1E}T2\u{1F}/Users/me/other\u{1F}~\u{1E}"
        let scripts = AppleScriptRunner { _ in .value(listing) }
        let model = await make(["a": AgentBoard.Agent(state: .working, since: start, tool: "claude", cwd: "/Users/me/proj", pid: 100)],
                               tree: processes, calls: calls, scripts: scripts, environments: ProcessEnvironment { _ in [:] })
        let ghostty = try row(model)
        #expect(ghostty.offersInput && ghostty.input == .ghostty(cwd: "/Users/me/proj", name: nil))
        model.focus(ghostty)
        await eventually { calls.log.count == 2 }
        #expect(calls.steps == [[.script(TerminalScripts.ghosttyFocus(terminal: "T1", folders: ["/Users/me/proj", "/Users/me/proj/"], name: "", needsName: false))]])
        #expect(calls.log == ["run", "activate:com.mitchellh.ghostty"])
    }
}
