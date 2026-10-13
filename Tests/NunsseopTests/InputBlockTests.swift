import Foundation
import Testing
@testable import Nunsseop

// Why a live session's message button is dimmed. Nothing here starts a terminal, types into one or reads a real process.

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func entry(_ agent: AgentBoard.Agent) -> AgentBoard.Entry {
    AgentBoard.Entry(source: "hooks:claude", id: "a", agent: agent)
}

private func agent(state: AgentBoard.State = .working, app: String? = nil, input: AgentInput? = nil, pid: Int32? = 100,
                   multiplexer: Bool = false) -> AgentBoard.Agent {
    AgentBoard.Agent(state: state, since: start, tool: "claude", app: app, input: input, pid: pid, inMultiplexer: multiplexer)
}

struct InputBlockDerivationTests {
    @Test func aSendableRowHasNoBlock() {
        let row = AgentRow(entry(agent(input: .muxy("42"))), transcript: nil, inputVerified: true)
        #expect(row.acceptsInput && row.inputBlock == nil && row.blockReason == nil)
    }

    @Test func aPromptBlocksARowThatCouldOtherwiseBeTypedInto() {
        let row = AgentRow(entry(agent(state: .waiting, input: .muxy("42"))), transcript: nil, inputVerified: true)
        // Not through `promptMayBeOpen`, which `effective(at:)` sets: ask for it as the board does.
        let asking = AgentRow(AgentBoard.Entry(source: "hooks:claude", id: "a", agent: agent(state: .waiting, input: .muxy("42")).effective(at: start)),
                              transcript: nil, inputVerified: true)
        #expect(!asking.acceptsInput && asking.inputBlock == .prompt && asking.blockReason == String(localized: "Answer the prompt first"))
        #expect(row.inputBlock == .prompt)
    }

    @Test func aPromptDoesNotHideWhyAnUnreachableRowCannotBeTypedInto() {
        let asking = agent(state: .waiting, multiplexer: true).effective(at: start)
        #expect(AgentRow(entry(asking), transcript: nil).inputBlock == .multiplexer)
    }

    @Test func aHerdrPaneIsNeverBlockedForWantOfATarget() {
        let pane = AgentBoard.Agent(state: .working, since: start, tool: "claude", input: .herdr(pane: "p", socket: "/tmp/h.sock"))
        #expect(AgentRow(AgentBoard.Entry(source: "herdr", id: "p", agent: pane), transcript: nil).inputBlock == nil)
    }

    @Test func tmuxZellijAndScreenComeFromTheHookOrTheProcessEnvironment() {
        #expect(AgentRow(entry(agent(multiplexer: true)), transcript: nil).inputBlock == .multiplexer)
        #expect(AgentRow(entry(agent()), transcript: nil, multiplexed: true).inputBlock == .multiplexer)
        // Ahead of the terminal around it, and of a missing process.
        #expect(AgentRow(entry(agent(app: "com.mitchellh.ghostty", pid: nil, multiplexer: true)), transcript: nil).inputBlock == .multiplexer)
    }

    @Test func aKnownTerminalWithoutAnInputApiIsNamed() {
        let warp = AgentRow(entry(agent(app: "dev.warp.Warp-Stable")), transcript: nil)
        #expect(warp.inputBlock == .unsupportedApp("dev.warp.Warp-Stable"))
        // The app found above the process stands in for a hook that sent none, and X-App wins over it.
        #expect(AgentRow(entry(agent()), transcript: nil, hostApp: "dev.warp.Warp-Stable").inputBlock == .unsupportedApp("dev.warp.Warp-Stable"))
        #expect(AgentRow(entry(agent(app: "dev.warp.Warp-Stable")), transcript: nil, hostApp: TerminalScripts.terminalID).inputBlock
                == .unsupportedApp("dev.warp.Warp-Stable"))
        // Even with no process to check: the app is the better answer.
        #expect(AgentRow(entry(agent(app: "dev.warp.Warp-Stable", pid: nil)), transcript: nil).inputBlock == .unsupportedApp("dev.warp.Warp-Stable"))
        // Ghostty can be typed into (through its tabs): not named as unsupported when it couldn't be confirmed.
        #expect(AgentRow(entry(agent(app: "com.mitchellh.ghostty")), transcript: nil).inputBlock == .unconfirmed)
    }

    @Test func everyTerminalWithAnInputApiCountsAsSupported() {
        for app in [TerminalScripts.terminalID, TerminalScripts.itermID, MuxyNotice.bundleID, Cmux.bundleID, WezTerm.bundleID, Kitty.bundleID,
                    TerminalScripts.ghosttyID] {
            let block = AgentRow(entry(agent(app: app)), transcript: nil).inputBlock
            #expect(block == .unconfirmed, Comment(rawValue: app))
        }
    }

    @Test func aSessionWithoutAProcessAsksForARestart() {
        #expect(AgentRow(entry(agent(pid: nil)), transcript: nil).inputBlock == .noProcess)
        #expect(AgentRow(entry(agent(app: TerminalScripts.terminalID, pid: nil)), transcript: nil).inputBlock == .noProcess)
        #expect(AgentRow(entry(agent(input: .muxy("42"), pid: nil)), transcript: nil).inputBlock == .noProcess)
    }

    @Test func aSupportedTerminalThatCouldNotBeVerifiedSaysSo() {
        #expect(AgentRow(entry(agent(input: .muxy("9999"))), transcript: nil, inputVerified: false).inputBlock == .unconfirmed)
        #expect(AgentRow(entry(agent()), transcript: nil).inputBlock == .unconfirmed)
    }

    @Test func aSourceThatIsNotAHookNeverAsksForARestartOrNamesAnApp() {
        // gjc and a herdr pane without its socket have no hook: restarting can't help, and no app is known of them.
        for source in ["gjc", "herdr"] {
            let other = AgentBoard.Entry(source: source, id: "a", agent: agent(app: "com.mitchellh.ghostty", pid: nil))
            #expect(AgentRow(other, transcript: nil, hostApp: "dev.warp.Warp-Stable").inputBlock == .unconfirmed, Comment(rawValue: source))
            let bare = AgentBoard.Entry(source: source, id: "a", agent: agent(pid: nil))
            #expect(AgentRow(bare, transcript: nil).inputBlock == .unconfirmed, Comment(rawValue: source))
        }
    }

    @Test func aRowTheCheckHasNotCoveredYetReadsCheckingUnlessItNeedsNoCheck() {
        #expect(AgentRow(entry(agent(input: .muxy("42"))), transcript: nil, checked: false).inputBlock == .checking)
        #expect(AgentRow(entry(agent()), transcript: nil, checked: false).inputBlock == .checking)
        #expect(AgentRow(entry(agent(app: "com.mitchellh.ghostty")), transcript: nil, checked: false).inputBlock == .checking)
        // No process, nothing to check; the tmux the hook reported stands.
        #expect(AgentRow(entry(agent(pid: nil)), transcript: nil, checked: false).inputBlock == .noProcess)
        #expect(AgentRow(entry(agent(multiplexer: true)), transcript: nil, checked: false).inputBlock == .multiplexer)
        // Once verified, nothing is dimmed whatever the flag says.
        #expect(AgentRow(entry(agent(input: .muxy("42"))), transcript: nil, inputVerified: true, checked: false).inputBlock == nil)
        #expect(AgentRow.InputBlock.checking.message == String(localized: "Checking…"))
    }

    @Test func eachReasonHasItsOwnSentence() {
        let messages = [AgentRow.InputBlock.prompt, .multiplexer, .unsupportedApp("dev.warp.Warp-Stable"), .noProcess, .unconfirmed, .checking,
                        .ambiguousTab, .notAllowed("com.mitchellh.ghostty")].map(\.message)
        #expect(Set(messages).count == 8)
        #expect(AgentRow.InputBlock.multiplexer.message == String(localized: "Can't send into tmux, zellij or screen"))
        #expect(AgentRow.InputBlock.noProcess.message == String(localized: "Restart this session to send to it"))
        #expect(AgentRow.InputBlock.unconfirmed.message == String(localized: "Couldn't confirm which terminal this session is in"))
        #expect(AgentRow.InputBlock.unsupportedApp("com.example.nosuchterminal").message.contains("nosuchterminal"))
    }

    @Test func anAppIsNamedByItsInstalledNameElseTheEndOfItsBundleId() {
        #expect(AgentRow.appName("com.mitchellh.ghostty", installed: { _ in "Ghostty.app" }) == "Ghostty")
        #expect(AgentRow.appName("com.mitchellh.ghostty", installed: { _ in "Ghostty" }) == "Ghostty")
        #expect(AgentRow.appName("com.mitchellh.ghostty", installed: { _ in nil }) == "ghostty")
        #expect(AgentRow.appName("com.mitchellh.ghostty", installed: { _ in "" }) == "ghostty")
        // A name found in a process tree has no dots to cut at; if it has, it isn't a bundle id.
        #expect(AgentRow.appName("Visual Studio Code", installed: { _ in nil }) == "Visual Studio Code")
        #expect(AgentRow.appName("Foo.bar Terminal", installed: { _ in nil }) == "Foo.bar Terminal")
    }

    @Test func theNewSentencesAreTranslatedIntoEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let keys = ["Checking…", "Can't send into tmux, zellij or screen", "%@ doesn't let Nunsseop type into it", "Restart this session to send to it",
                    "Couldn't confirm which terminal this session is in"]
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for key in keys {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language): \(key)"))
            }
            #expect((table["%@ doesn't let Nunsseop type into it"] as? String)?.contains("%@") == true, Comment(rawValue: language))
        }
    }
}

struct MultiplexerHeaderTests {
    private let base = ["x-session": "s", "x-event": "Stop", "x-pid": "4321"]
    private let table = ProcessTable { _ in .init(parent: 2, executable: "/usr/bin/claude", hasTTY: true, tty: "/dev/ttys009") }

    @Test func theHooksMuxHeaderIsKeptOnTheEvent() {
        #expect(AgentHook.event(headers: base.merging(["x-mux": "1", "x-muxy": "42"]) { $1 }, processes: table)?.inMultiplexer == true)
        #expect(AgentHook.event(headers: base, processes: table)?.inMultiplexer == false)
        #expect(AgentHook.event(headers: base.merging(["x-mux": ""]) { $1 }, processes: table)?.inMultiplexer == false)
    }

    @Test func theEnvironmentsMultiplexerVariablesAreRecognised() {
        for name in ["TMUX", "ZELLIJ", "STY"] { #expect(AgentHook.inMultiplexer(environment: [name: "x"]), Comment(rawValue: name)) }
        #expect(!AgentHook.inMultiplexer(environment: ["TMUX": "", "MUXY_SESSION_ID": "42"]))
        #expect(!AgentHook.inMultiplexer(environment: [:]))
    }

    @MainActor
    @Test func theFlagReachesTheBoardAndSurvivesAnApp​Activation() {
        let board = AgentBoard()
        let hooks = AgentHooks(board: board, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }, isAlive: { _ in true })
        hooks.apply(AgentEvent(session: "a", action: .finished, app: "x.y", pid: 100, inMultiplexer: true), now: start)
        #expect(board.entries(now: start).first?.agent.inMultiplexer == true)
        hooks.activated("x.y")
        #expect(board.entries(now: start).first?.agent.inMultiplexer == true)
        // A later event from the same session outside tmux (resumed elsewhere) clears it.
        hooks.apply(AgentEvent(session: "a", action: .opened, pid: 100), now: start)
        #expect(board.entries(now: start).first?.agent.inMultiplexer == false)
    }
}

struct HostAppTests {
    private func check(_ records: [Int32: ProcessRecord]) -> AgentTargetCheck {
        AgentTargetCheck(processes: ProcessTable { records[$0] }, muxyList: { _ in nil })
    }

    @Test func theNearestAppAboveTheProcessIsFoundByItsOutermostBundle() {
        let claude = "/Users/me/.local/share/claude/versions/2.1"
        let tree: [Int32: ProcessRecord] = [
            100: .init(parent: 101, executable: claude, hasTTY: true),
            101: .init(parent: 102, executable: "/bin/zsh", hasTTY: true),
            102: .init(parent: 103, executable: "/Applications/Fake Editor.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", hasTTY: false),
            103: .init(parent: 1, executable: "/Applications/Fake Editor.app/Contents/MacOS/Electron", hasTTY: false),
        ]
        #expect(check(tree).hostApp(pid: 100) == "Fake Editor")
    }

    @Test func anUnreadableBundleOfATerminalWeCanTypeIntoIsNotNamedAsAnUnsupportedOne() {
        // These paths hold no bundle here, as when the app was replaced while the session ran.
        let tree: [Int32: ProcessRecord] = [
            100: .init(parent: 101, executable: "/usr/local/bin/claude", hasTTY: true),
            101: .init(parent: 1, executable: "/Nonexistent/iTerm.app/Contents/MacOS/iTerm2", hasTTY: false),
        ]
        #expect(check(tree).hostApp(pid: 100) == nil)
    }

    @Test func theSessionsOwnBundleIsNotItsTerminalAndNoAppGivesNil() {
        let tree: [Int32: ProcessRecord] = [
            100: .init(parent: 101, executable: "/Applications/Claude.app/Contents/MacOS/claude", hasTTY: true),
            101: .init(parent: 102, executable: "/bin/zsh", hasTTY: true),
            102: .init(parent: 1, executable: "/usr/local/bin/tmux", hasTTY: false),
        ]
        #expect(check(tree).hostApp(pid: 100) == nil)
        #expect(check([:]).hostApp(pid: 100) == nil)
        // A loop in the table ends.
        #expect(check([100: .init(parent: 101, executable: nil, hasTTY: true), 101: .init(parent: 100, executable: nil, hasTTY: true)]).hostApp(pid: 100) == nil)
    }
}

/// Made-up environments by pid.
private struct FakeEnvironments {
    var variables: [Int32: [String: String]] = [:]
    var environment: ProcessEnvironment { let variables = variables; return ProcessEnvironment { variables[$0] } }
}

@MainActor
struct InputBlockModelTests {
    let clis = TerminalCLIs(muxy: URL(fileURLWithPath: "/m/muxy"), cmux: URL(fileURLWithPath: "/c/cmux"))
    private let claude = "/Users/me/.local/share/claude/versions/2.1"

    /// 100: in Muxy (a genuine session); 200: under an app with no input API; 300: in tmux under Terminal; 400: under Terminal, whose device the hook didn't give.
    private var tree: [Int32: ProcessRecord] {
        [
            100: .init(parent: 101, executable: claude, hasTTY: true), 101: .init(parent: 102, executable: "/bin/zsh", hasTTY: true),
            102: .init(parent: 1, executable: "/Applications/Muxy.app/Contents/MacOS/muxy-server", hasTTY: false),
            200: .init(parent: 201, executable: claude, hasTTY: true), 201: .init(parent: 202, executable: "/bin/zsh", hasTTY: true),
            202: .init(parent: 1, executable: "/Applications/NoSuchTerm.app/Contents/MacOS/nosuch", hasTTY: false),
            300: .init(parent: 301, executable: claude, hasTTY: true), 301: .init(parent: 302, executable: "/bin/zsh", hasTTY: true),
            302: .init(parent: 1, executable: "/opt/homebrew/bin/tmux", hasTTY: false),
        ]
    }

    private func make(_ agents: [String: AgentBoard.Agent], environments: [Int32: [String: String]] = [:]) -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: agents, now: start)
        let records = tree
        let check = AgentTargetCheck(processes: ProcessTable { records[$0] }, muxyList: { _ in "42\tname\tLive\ttrue\t/tmp\n" })
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: AgentSender { _ in .sent }, clis: { clis }, targets: check,
                                   environments: FakeEnvironments(variables: environments).environment)
        model.fixedRecent = []
        return model
    }

    private func settle(_ model: AgentsTabModel) async {
        model.refresh(now: start)
        await eventually { !model.verifying }
    }

    private func row(_ model: AgentsTabModel, _ id: String) throws -> AgentRow {
        try #require(model.rows.first { $0.id == "hooks:claude|\(id)" })
    }

    @Test func theModelDerivesEachReasonFromWhatItVerifiedAndFound() async throws {
        let model = make([
            "ok": agent(input: .muxy("42"), pid: 100),
            "hookTmux": agent(pid: 300, multiplexer: true),
            "envTmux": agent(pid: 300),
            "warpApp": agent(app: "dev.warp.Warp-Stable", pid: 200),
            "ghosttyApp": agent(app: "com.mitchellh.ghostty", pid: 200),
            "ghosttyTree": agent(pid: 200),
            "oldHook": agent(pid: nil),
            "gone": agent(input: .muxy("9999"), pid: 100),
        ], environments: [300: ["TMUX": "/tmp/tmux-501/default,1,0", "MUXY_SESSION_ID": "42"]])
        await settle(model)
        #expect(try row(model, "ok").inputBlock == nil)
        #expect(try row(model, "hookTmux").inputBlock == .multiplexer)
        #expect(try row(model, "envTmux").inputBlock == .multiplexer)
        #expect(try row(model, "warpApp").inputBlock == .unsupportedApp("dev.warp.Warp-Stable"))
        // Ghostty is typed into, but this session's process isn't under it here.
        #expect(try row(model, "ghosttyApp").inputBlock == .unconfirmed)
        // Found in the process tree: no bundle is on disk here, so it is named by the app's folder.
        #expect(try row(model, "ghosttyTree").inputBlock == .unsupportedApp("NoSuchTerm"))
        #expect(try row(model, "ghosttyTree").blockReason == AgentRow.InputBlock.unsupportedApp("NoSuchTerm").message)
        #expect(try row(model, "oldHook").inputBlock == .noProcess)
        #expect(try row(model, "gone").inputBlock == .unconfirmed)
    }

    @Test func aRowReadsCheckingUntilTheFirstPassCoversItThenItsRealReason() async throws {
        let model = make([
            "named": agent(input: .muxy("42"), pid: 100), "unnamed": agent(pid: 100), "ghostty": agent(pid: 200), "oldHook": agent(pid: nil),
        ], environments: [100: ["MUXY_SESSION_ID": "42"]])
        model.refresh(now: start)
        #expect(model.verifying)
        for id in ["named", "unnamed", "ghostty"] {
            #expect(try row(model, id).inputBlock == .checking, Comment(rawValue: id))
            model.compose(try row(model, id))
            #expect(model.composing == nil, Comment(rawValue: id))
        }
        // Nothing to check without a process.
        #expect(try row(model, "oldHook").inputBlock == .noProcess)
        await eventually { !model.verifying }
        #expect(try row(model, "named").inputBlock == nil)
        #expect(try row(model, "unnamed").inputBlock == nil)
        #expect(try row(model, "ghostty").inputBlock == .unsupportedApp("NoSuchTerm"))
    }

    @Test func aSessionThatAppearsAfterAPassReadsCheckingUntilTheNextOne() async throws {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(input: .muxy("42"), pid: 100)], now: start)
        let records = tree
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: AgentSender { _ in .sent }, clis: { clis },
                                   targets: AgentTargetCheck(processes: ProcessTable { records[$0] }, muxyList: { _ in "42\tn\tLive\ttrue\t/tmp\n" }),
                                   environments: FakeEnvironments().environment)
        model.fixedRecent = []
        await settle(model)
        board.replace(source: "hooks:claude", with: ["a": agent(input: .muxy("42"), pid: 100), "b": agent(input: .muxy("42"), pid: 100)], now: start)
        model.refresh(now: start)
        // Rebuilt before the second pass ends: the old row keeps its answer, the new one waits for its own.
        #expect(try row(model, "a").inputBlock == nil)
        #expect(try row(model, "b").inputBlock == .checking)
        await eventually { !model.verifying }
        #expect(try row(model, "b").inputBlock == nil)
    }

    @Test func aSessionInANewTerminalNoLongerCarriesTheOldOnesApp() async throws {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(pid: 200)], now: start)
        let records = tree
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: AgentSender { _ in .sent }, clis: { clis },
                                   targets: AgentTargetCheck(processes: ProcessTable { records[$0] }, muxyList: { _ in nil }),
                                   environments: FakeEnvironments().environment)
        model.fixedRecent = []
        await settle(model)
        #expect(try row(model, "a").inputBlock == .unsupportedApp("NoSuchTerm"))
        board.replace(source: "hooks:claude", with: [:], now: start)
        await settle(model)
        board.replace(source: "hooks:claude", with: ["a": agent(pid: nil)], now: start)
        await settle(model)
        #expect(try row(model, "a").inputBlock == .noProcess)
    }

    @Test func aDimmedButtonDoesNotOpenTheFieldOrSendAnything() async throws {
        let model = make([
            "hookTmux": agent(pid: 300, multiplexer: true), "ghostty": agent(app: "com.mitchellh.ghostty", pid: 200),
            "oldHook": agent(pid: nil), "gone": agent(input: .muxy("9999"), pid: 100),
            "asking": agent(state: .waiting, input: .muxy("42"), pid: 100),
        ])
        await settle(model)
        for id in ["hookTmux", "ghostty", "oldHook", "gone", "asking"] {
            let blocked = try row(model, id)
            #expect(blocked.inputBlock != nil && !blocked.acceptsInput, Comment(rawValue: id))
            model.compose(blocked)
            #expect(model.composing == nil, Comment(rawValue: id))
            #expect(!model.send(message: "hello", to: blocked), Comment(rawValue: id))
            #expect(!model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: blocked), Comment(rawValue: id))
            #expect(model.notes[blocked.id] == nil, Comment(rawValue: id))
        }
    }
}
