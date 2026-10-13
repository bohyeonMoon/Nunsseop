import AppKit

/// What a click on a session's row does: go to the tab or pane the session is in, when its terminal is known and verified, else
/// only bring forward the app. A terminal that was only guessed at (see `AgentTargetCheck`) is never focused: it could be another session's.
enum AgentFocus {
    enum Plan: Equatable {
        /// herdr's own pane (see `Herdr.focus`), which also brings forward the app its client runs in.
        case herdr(pane: String, socket: String)
        /// The calls that select the session's tab or pane, then `app` is brought forward whether they worked or not.
        case terminal([AgentStep], app: String)
        /// Only the app: the session's terminal has no call for its tab, or none was verified.
        case app(String)
        case nothing
    }

    /// What a click on this row does. `ghostty` is the terminal picked for a Ghostty row (see `Ghostty.resolve`), `orca` the handle of
    /// the pane of an Orca row.
    static func plan(for row: AgentRow, clis: TerminalCLIs, ghostty: GhosttyPick? = nil, orca: OrcaPick? = nil) -> Plan {
        if case .herdr(let pane, let socket)? = row.target { return .herdr(pane: pane, socket: socket) }
        if row.offersInput || row.listedByTerminal, let input = row.input, let app = bundleID(of: input) {
            return steps(input, clis: clis, ghostty: ghostty, orca: orca, folder: row.listedByTerminal ? row.path : nil)
                .map { .terminal($0, app: app) } ?? .app(app)
        }
        if case .app(let id)? = row.target { return .app(id) }
        return .nothing
    }

    /// The app a terminal's input belongs to; nil for herdr, which has no app of its own.
    static func bundleID(of input: AgentInput) -> String? {
        switch input {
        case .muxy: Muxy.bundleID
        case .cmux: Cmux.bundleID
        case .herdr: nil
        case .terminalApp: TerminalScripts.terminalID
        case .iterm: TerminalScripts.itermID
        case .wezterm: WezTerm.bundleID
        case .kitty: Kitty.bundleID
        case .ghostty: TerminalScripts.ghosttyID
        case .orca: Orca.bundleID
        }
    }

    /// The calls that select the session's tab or pane, with the same ids and the same check of the tab as sending; nil when the
    /// terminal's tool isn't there (or, for Ghostty, no tab was picked). Muxy has no call for a session's tab (tabs belong to the
    /// app's UI): the bridge extension selects it, and without that the session's project is opened.
    /// - folder: the project Muxy lists the session in, for when the desktop state has no pane for it.
    static func steps(_ input: AgentInput, clis: TerminalCLIs, ghostty: GhosttyPick?, orca: OrcaPick? = nil, folder: String? = nil) -> [AgentStep]? {
        switch input {
        case .muxy(let session):
            return [.muxyFocus(session: session, folder: folder)]
        case .cmux(let surface):
            guard let cli = clis.cmux else { return nil }
            return [.run(cli, ["focus-panel", "--panel", surface])]
        case .herdr:
            return nil
        case .terminalApp(let tty):
            return [.script(TerminalScripts.terminalFocus(tty: tty))]
        case .iterm(let tty):
            return [.script(TerminalScripts.itermFocus(tty: tty))]
        case .wezterm(let pane, let socket):
            guard let cli = clis.wezterm else { return nil }
            return [.runWith(cli, ["cli", "--no-auto-start", "activate-pane", "--pane-id", pane], variables: ["WEZTERM_UNIX_SOCKET": socket])]
        case .kitty(let window, let socket):
            guard let cli = clis.kitty else { return nil }
            return [.run(cli, ["@", "--to", socket, "focus-window", "--match", "id:\(window)"])]
        case .ghostty(let cwd, let name):
            guard let ghostty, let folder = Ghostty.normalized(cwd) else { return nil }
            let usable = Ghostty.usableName(name)
            return [.script(TerminalScripts.ghosttyFocus(terminal: ghostty.terminal, folders: Ghostty.spellings(of: folder), name: usable,
                                                         needsName: ghostty.usesName && !usable.isEmpty))]
        case .orca(let paneKey):
            guard let cli = clis.orca, let orca, orca.paneKey == paneKey else { return nil }
            return [.run(cli, ["terminal", "switch", "--terminal", orca.handle])]
        }
    }
}

/// Runs what a click does: the calls off the main thread, the activation on it. Tests give it one that records.
struct AgentFocuser {
    var run: @Sendable ([AgentStep]) -> SendOutcome
    /// Brings the app with this bundle id forward; called on the main thread.
    var activate: @Sendable (String) -> Void
    /// Focuses a herdr pane (which does its own work off the main thread); called on the main thread.
    var herdr: @Sendable (_ pane: String, _ socket: String) -> Void

    /// The real tools; the AppleScript steps through `scripts`.
    static func live(scripts: AppleScriptRunner = .live) -> AgentFocuser {
        AgentFocuser(run: { AgentSend.run($0, scripts: scripts) },
                     activate: { TerminalFocus.activate(bundleID: $0) },
                     herdr: { Herdr.focus(pane: $0, socket: URL(fileURLWithPath: $1)) })
    }
}
