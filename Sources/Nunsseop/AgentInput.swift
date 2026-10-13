import AppKit

/// Where text for a session goes: the input API of the terminal it runs in. Only terminals that have one are listed;
/// nothing is ever sent as synthetic key events.
enum AgentInput: Equatable {
    /// A Muxy terminal session (`MUXY_SESSION_ID`).
    case muxy(String)
    /// A cmux terminal surface (`CMUX_SURFACE_ID`).
    case cmux(String)
    /// A herdr pane and the socket of its session.
    case herdr(pane: String, socket: String)
    /// Terminal.app: the tab whose `tty` is this device (`/dev/ttysNNN`), which only takes text together with a Return.
    case terminalApp(tty: String)
    /// iTerm2: the session whose `tty` is this device.
    case iterm(tty: String)
    /// A WezTerm pane (`WEZTERM_PANE`) and the socket of the instance it is in (`WEZTERM_UNIX_SOCKET`): pane ids start at 0 in
    /// each GUI process, so the tool must be pointed at that one.
    case wezterm(pane: String, socket: String)
    /// A kitty window (`KITTY_WINDOW_ID`) and the socket its remote control listens on (`KITTY_LISTEN_ON`, `unix:/path`).
    case kitty(window: String, socket: String)
    /// A Ghostty terminal, found by the session's folder among the tabs with a Claude title and, among several in it, by its name in
    /// that title: Ghostty gives a shell no id of its own. Which terminal it is comes from `Ghostty.resolve`, so the id is not part of this.
    case ghostty(cwd: String, name: String?)
    /// An Orca pane (`ORCA_PANE_KEY`, `<tab id>:<leaf UUID>`). Orca's tool addresses a terminal by a handle it lists for the pane (see
    /// `OrcaPick`), which is looked up on every verification pass, so the key alone sends nothing.
    case orca(paneKey: String)
    /// An agent of Paseo, and the id of its server for the link that opens it. It has no terminal: its text goes in through
    /// Paseo's command line, which always sends it as a message.
    case paseo(agent: String, server: String?)

    /// A Muxy session id from the hook: 1 to 20 ASCII digits (a 64-bit id).
    static func muxySession(_ value: String?) -> String? {
        guard let value, (1...20).contains(value.utf8.count),
              value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        return value
    }

    /// A cmux surface id from the hook: a UUID, so hex digits and dashes, 8 to 64 of them, not starting with a dash.
    static func cmuxSurface(_ value: String?) -> String? {
        guard let value, (8...64).contains(value.utf8.count), value.utf8.first != UInt8(ascii: "-"),
              value.utf8.allSatisfy({ $0 == UInt8(ascii: "-") || Character(UnicodeScalar($0)).isHexDigit }) else { return nil }
        return value
    }

    /// An Orca pane key from the hook: a tab id (1 to 64 ASCII letters, digits, `_`, `.` and `-`), a colon and the pane's UUID as Orca
    /// writes it (lowercase, version 1 to 5, variant 8 to b).
    static func orcaPane(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 101, let colon = value.firstIndex(of: ":") else { return nil }
        let tab = value[..<colon], leaf = Array(value[value.index(after: colon)...].utf8)
        guard (1...64).contains(tab.utf8.count), tab.utf8.allSatisfy(isPlainID), leaf.count == 36 else { return nil }
        let hex = { (byte: UInt8) in (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte) }
        for (index, byte) in leaf.enumerated() {
            switch index {
            case 8, 13, 18, 23: if byte != UInt8(ascii: "-") { return nil }
            case 14: if !(UInt8(ascii: "1")...UInt8(ascii: "5")).contains(byte) { return nil }
            case 19: if !"89ab".utf8.contains(byte) { return nil }
            default: if !hex(byte) { return nil }
            }
        }
        return value
    }

    /// A terminal handle from Orca's listing (`term_` and a UUID): 1 to 128 ASCII letters, digits, `_` and `-`, not starting with a dash,
    /// which the tool would take for an option.
    static func orcaHandle(_ value: String?) -> String? {
        guard let value, (1...128).contains(value.utf8.count), value.utf8.first != UInt8(ascii: "-"),
              value.utf8.allSatisfy({ $0 == UInt8(ascii: "-") || isPlainID($0) && $0 != UInt8(ascii: ".") }) else { return nil }
        return value
    }

    private static func isPlainID(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || "_.-".utf8.contains(byte)
    }

    /// A WezTerm pane or kitty window id from the hook: 1 to 10 ASCII digits.
    static func numericID(_ value: String?) -> String? {
        guard let value, (1...10).contains(value.utf8.count),
              value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        return value
    }

    /// The address kitty's remote control listens on, from `KITTY_LISTEN_ON`: `unix:` and an absolute path of at most 100 plain
    /// characters (a socket path holds 103) without a `..` part. A TCP address or an abstract socket is refused.
    static func kittySocket(_ value: String?) -> String? {
        guard let value, value.hasPrefix("unix:/"), value.utf8.count <= 105, plainSocketPath(value.dropFirst("unix:".count)) else { return nil }
        return value
    }

    /// The socket of a WezTerm instance, from `WEZTERM_UNIX_SOCKET`: an absolute path (no `unix:`), as plain as kitty's.
    static func weztermSocket(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.utf8.count <= 100, plainSocketPath(value[...]) else { return nil }
        return value
    }

    private static func plainSocketPath(_ path: Substring) -> Bool {
        path.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "/._-+=,@%:".unicodeScalars.contains($0)) }
            && !path.split(separator: "/").contains("..")
    }

    /// An iTerm2 session id from the hook (`w0t0p0:` and a UUID): letters, digits, colons and dashes, up to 64.
    static func itermSession(_ value: String?) -> String? {
        guard let value, (1...64).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == ":" || $0 == "-") }) else { return nil }
        return value
    }

    /// A terminal device as Terminal.app and iTerm2 name it: `/dev/ttys` and 1 to 6 digits.
    static func ttyDevice(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/dev/ttys") else { return nil }
        let digits = value.dropFirst("/dev/ttys".count)
        return (1...6).contains(digits.utf8.count) && digits.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) ? value : nil
    }

    /// Whether dropped file paths can be typed there. Terminal.app can't: it runs what it is given. Nor can Paseo: its command line
    /// sends a message, never half of one.
    var takesFiles: Bool {
        switch self {
        case .terminalApp, .paseo: false
        default: true
        }
    }
}

/// One call to a terminal's input API; a plan is a list of them, run in order until one fails.
enum AgentStep: Equatable {
    /// Runs a command-line tool with exactly these arguments (never through a shell); passes on exit status 0.
    case run(URL, [String])
    /// Like `run`, with these variables added to the environment.
    case runWith(URL, [String], variables: [String: String])
    /// Runs a tool and passes only when a line of its output starts with `id` and a tab: Muxy's session list.
    case listed(URL, [String], id: String)
    /// Sends JSON requests to a Unix socket, each on a connection of its own (herdr answers one request per connection, then
    /// closes it); passes when each is answered and none with an error.
    case socket(path: String, requests: [String])
    /// Runs a tool with `stdin` as its standard input, which it takes as it is (kitty's `send-text --stdin` does not read escapes).
    case runInput(URL, [String], stdin: String)
    /// Calls a handler of an AppleScript in a terminal app, which takes the text as an argument. Passes when it answers `expecting`.
    case script(AppleScriptCall)
    /// Goes to a Muxy session: its own tab through the bridge extension when that runs, else its project (see `MuxyFocus`). Passes when
    /// either worked.
    /// `folder`: the project's, for a session the desktop state has no pane for.
    case muxyFocus(session: String, folder: String? = nil)
}

/// The command-line tools of the terminals that take input; nil for one that isn't installed.
struct TerminalCLIs {
    var muxy: URL?
    var cmux: URL?
    var wezterm: URL?
    var kitty: URL?
    var orca: URL?
    var paseo: URL?

    static var live: TerminalCLIs {
        TerminalCLIs(muxy: Muxy.cli, cmux: Cmux.cli, wezterm: WezTerm.cli, kitty: Kitty.cli, orca: Orca.cli, paseo: Paseo.cli())
    }
}

/// What may be sent to a session, and how it reaches each terminal.
enum AgentSend {
    /// The longest message sent.
    static let maxLength = 4000

    /// Variables that would point a terminal's tool at Nunsseop's own terminal, if it was started from one: `muxy session send`
    /// types into the terminal named by `MUXY_SESSION_ID` when it is not given a live session of its own.
    static let terminalVariables = ["MUXY_SESSION_ID", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_PANEL_ID", "CMUX_PANE_ID", "CMUX_TAB_ID",
                                    "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET", "KITTY_WINDOW_ID", "KITTY_LISTEN_ON"]

    /// A message as the one line the agent takes: control characters (CR, LF and TAB too) and line separators become spaces,
    /// the ends are trimmed, and it is cut at `maxLength`. nil when nothing is left.
    static func message(_ text: String) -> String? {
        var line = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let breaks = scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
            line.append(breaks ? " " : scalar)
        }
        let trimmed = String(String(line).prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A path as Claude Code and Codex take it pasted: as it is, or in single quotes (`'\''` for a quote inside) when it holds a
    /// space or a character a shell treats specially. nil for a path with a control character.
    static func quoted(path: String) -> String? {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        let plain = path.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII ? (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "_@%+=:,./-".unicodeScalars.contains(scalar))
                           : !scalar.properties.isWhitespace
        }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The paths of the file URLs among `urls`, quoted, joined by spaces, with a space after the last so the next word is apart
    /// from it. nil when there is none, or when one has a control character: nothing is sent then.
    static func paths(_ urls: [URL]) -> String? {
        let files = urls.filter(\.isFileURL)
        let words = files.compactMap { quoted(path: $0.path) }
        guard !files.isEmpty, words.count == files.count else { return nil }
        return words.joined(separator: " ") + " "
    }

    /// Whether a session in this state takes input. One waiting on a permission prompt or a question doesn't: typing could answer
    /// it. A finished one ("Your turn"), an idle one and a working one do (Claude Code queues what is typed while it works).
    static func accepts(state: AgentBoard.State, finished: Bool) -> Bool {
        state != .waiting || finished
    }

    /// The calls that put `text` into the session, followed by Return when `submit`; nil when its terminal's tool isn't there.
    /// `ghostty` is the terminal picked for a Ghostty session (see `Ghostty.resolve`); without it there is no plan. `orca` is the same
    /// for an Orca pane, and must be the pane's own.
    static func steps(_ input: AgentInput, text: String, submit: Bool, clis: TerminalCLIs, ghostty: GhosttyPick? = nil, orca: OrcaPick? = nil) -> [AgentStep]? {
        switch input {
        case .muxy(let session):
            guard let cli = clis.muxy else { return nil }
            // Without a live session of that id the tool takes the id for part of the text and types it into its own default
            // terminal, so the list is looked at first. A text starting with a dash needs `--` to be taken as text.
            return [.listed(cli, ["session", "list"], id: session),
                    .run(cli, ["session", "send", session] + (text.hasPrefix("-") ? ["--"] : []) + [text])]
                + (submit ? [.run(cli, ["session", "send-keys", session, "Enter"])] : [])
        case .cmux(let surface):
            // `cmux send` reads \n, \r, \t and \u escapes in its text, so a backslash in a message could press Return; the
            // method it calls takes the text as it is.
            guard let cli = clis.cmux, let params = json(["surface_id": surface, "text": text]) else { return nil }
            return [.run(cli, ["rpc", "surface.send_text", params])]
                + (submit ? [.run(cli, ["send-key", "--surface", surface, "enter"])] : [])
        case .herdr(let pane, let socket):
            // One request does both: herdr's socket closes after answering the first, so a second one would never arrive.
            let params: [String: Any] = ["pane_id": pane, "text": text]
            return [.socket(path: socket, requests: [request("in", "pane.send_input", submit ? params.merging(["keys": ["enter"]]) { $1 } : params)])]
        case .terminalApp(let tty):
            // `do script` types the text and presses Return in one go: there is no way to type without it.
            return submit ? [.script(TerminalScripts.terminalSend(tty: tty, text: text))] : nil
        case .iterm(let tty):
            return [.script(TerminalScripts.itermSend(tty: tty, text: text, submit: submit))]
        case .wezterm(let pane, let socket):
            // Typed (not pasted), so the Return after it is not part of a paste; `--` keeps a text starting with a dash from being an option.
            // The tool finds its instance by the socket in its environment, and the pane id means nothing in another one.
            guard let cli = clis.wezterm else { return nil }
            let send = ["cli", "--no-auto-start", "send-text", "--pane-id", pane, "--no-paste", "--"]
            let variables = ["WEZTERM_UNIX_SOCKET": socket]
            return [.runWith(cli, send + [text], variables: variables)] + (submit ? [.runWith(cli, send + ["\r"], variables: variables)] : [])
        case .kitty(let window, let socket):
            // The text goes in on stdin, which kitty sends as it is; as an argument it would read `\r` and the like as escapes.
            guard let cli = clis.kitty else { return nil }
            let remote = ["@", "--to", socket]
            return [.runInput(cli, remote + ["send-text", "--match", "id:\(window)", "--stdin"], stdin: text)]
                + (submit ? [.run(cli, remote + ["send-key", "--match", "id:\(window)", "enter"])] : [])
        case .paseo(let agent, _):
            // `--no-wait` returns at once instead of after the turn; the text goes in as the option's own value (`--prompt=`), so a message
            // starting with a dash is not taken for an option. The command line interrupts an agent that is working, so a row only offers
            // this to one that is not (see `AgentRow.acceptsInput`), and drops no text of a half message.
            guard submit, Paseo.isSafeID(agent), let cli = clis.paseo else { return nil }
            return [Paseo.run(cli, ["send", agent, "--no-wait", "--prompt=" + text])]
        case .ghostty(let cwd, let name):
            // `input text` pastes, so a drop needs no Return and a message gets its own key. The script finds the terminal again by id
            // and types only if it still holds the folder and a Claude title (and the name, when that told it from the others). The
            // name goes in whenever it is long enough to look for in other tabs; `usesName` says whether this tab was found by it.
            guard let ghostty, let folder = Ghostty.normalized(cwd) else { return nil }
            let usable = Ghostty.usableName(name)
            return [.script(TerminalScripts.ghosttySend(terminal: ghostty.terminal, folders: Ghostty.spellings(of: folder), name: usable,
                                                        needsName: ghostty.usesName && !usable.isEmpty, text: text, submit: submit))]
        case .orca(let paneKey):
            // Orca's tool reads no escapes in a text: it goes to the terminal as JSON. The Return is a call of its own: text and `--enter`
            // together make newer Orca builds hold the call 1.5 to 8 seconds in Claude Code and Codex (past `TerminalFocus.run`'s limit,
            // which would leave the message typed and unsent), and older ones, or other agents, write both in one go, which a TUI can
            // swallow the Return of. `--text=` because a text starting with `--` would be taken for an option.
            guard let cli = clis.orca, let orca, orca.paneKey == paneKey else { return nil }
            let send = ["terminal", "send", "--terminal", orca.handle]
            return [.run(cli, send + ["--text=" + text])] + (submit ? [.run(cli, send + ["--enter"])] : [])
        }
    }

    private static func json(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private static func request(_ id: String, _ method: String, _ params: [String: Any]) -> String {
        json(["id": id, "method": method, "params": params]) ?? ""
    }

    /// The environment the terminals' tools run in: Nunsseop's own, less `terminalVariables` and Orca's `ORCA_*` (which pick the instance
    /// Orca's tool talks to, a paired server, and the terminal it acts for).
    static var cleanEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !terminalVariables.contains($0.key) && !$0.key.hasPrefix("ORCA_") }
    }

    /// Runs a step; false when it fails or the tool doesn't answer in time.
    static func execute(_ step: AgentStep, scripts: AppleScriptRunner = .live) -> Bool {
        perform(step, scripts: scripts) == .sent
    }

    /// Runs a step. `notAllowed` when macOS refused Nunsseop's Apple Events to the app (Automation, -1743).
    static func perform(_ step: AgentStep, scripts: AppleScriptRunner = .live) -> SendOutcome {
        let environment = cleanEnvironment
        switch step {
        case .run(let cli, let arguments):
            return TerminalFocus.run(cli, arguments, environment: environment) != nil ? .sent : .failed
        case .runWith(let cli, let arguments, let variables):
            return TerminalFocus.run(cli, arguments, environment: environment.merging(variables) { $1 }) != nil ? .sent : .failed
        case .runInput(let cli, let arguments, let stdin):
            return TerminalFocus.run(cli, arguments, environment: environment, input: stdin) != nil ? .sent : .failed
        case .listed(let cli, let arguments, let id):
            return TerminalFocus.run(cli, arguments, environment: environment)?
                .split(separator: "\n").contains { $0.split(separator: "\t", omittingEmptySubsequences: false).first == Substring(id) } == true ? .sent : .failed
        case .socket(let path, let requests):
            return requests.allSatisfy { request in
                guard let reply = TerminalFocus.send([request], toSocket: path).first else { return false }
                return ((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]).map { $0["error"] == nil } ?? false
            } ? .sent : .failed
        case .muxyFocus(let session, let folder):
            return MuxyFocus.run(session: session, folder: folder) ? .sent : .failed
        case .script(let call):
            switch scripts.run(call) {
            case .value(let answer): return answer == call.expecting ? .sent : .failed
            case .notAllowed: return .notAllowed(call.bundleID)
            case .failed: return .failed
            }
        }
    }

    /// Runs a plan, step by step, until one fails.
    static func run(_ steps: [AgentStep], scripts: AppleScriptRunner = .live) -> SendOutcome {
        for step in steps {
            let outcome = perform(step, scripts: scripts)
            if outcome != .sent { return outcome }
        }
        return .sent
    }
}

/// How a plan ended.
enum SendOutcome: Equatable {
    case sent
    case failed
    /// macOS refused to let Nunsseop control the app with this bundle id.
    case notAllowed(String)
}

/// Runs a plan off the main thread. Tests give it a runner that records the steps instead of running them.
struct AgentSender {
    var run: @Sendable ([AgentStep]) -> SendOutcome

    static let live = AgentSender { AgentSend.run($0) }

    /// The real tools, but with `scripts` for the AppleScript steps.
    static func live(scripts: AppleScriptRunner) -> AgentSender { AgentSender { AgentSend.run($0, scripts: scripts) } }
}
