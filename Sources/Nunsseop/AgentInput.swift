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
}

/// One call to a terminal's input API; a plan is a list of them, run in order until one fails.
enum AgentStep: Equatable {
    /// Runs a command-line tool with exactly these arguments (never through a shell); passes on exit status 0.
    case run(URL, [String])
    /// Runs a tool and passes only when a line of its output starts with `id` and a tab: Muxy's session list.
    case listed(URL, [String], id: String)
    /// Writes JSON requests, one per line, to a Unix socket; passes when each is answered and none with an error.
    case socket(path: String, requests: [String])
}

/// The command-line tools of the terminals that take input; nil for one that isn't installed.
struct TerminalCLIs {
    var muxy: URL?
    var cmux: URL?

    static var live: TerminalCLIs { TerminalCLIs(muxy: MuxyNotice.cli, cmux: Cmux.cli) }
}

extension MuxyNotice {
    static var cli: URL? {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .appendingPathComponent("Contents/MacOS/muxy")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }
}

/// What may be sent to a session, and how it reaches each terminal.
enum AgentSend {
    /// The longest message sent.
    static let maxLength = 4000

    /// Variables that would point a terminal's tool at Nunsseop's own terminal, if it was started from one: `muxy session send`
    /// types into the terminal named by `MUXY_SESSION_ID` when it is not given a live session of its own.
    static let terminalVariables = ["MUXY_SESSION_ID", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_PANEL_ID", "CMUX_PANE_ID", "CMUX_TAB_ID"]

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
    static func steps(_ input: AgentInput, text: String, submit: Bool, clis: TerminalCLIs) -> [AgentStep]? {
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
            let requests = [request("text", "pane.send_text", ["pane_id": pane, "text": text])]
                + (submit ? [request("enter", "pane.send_keys", ["pane_id": pane, "keys": ["enter"]])] : [])
            return [.socket(path: socket, requests: requests)]
        }
    }

    private static func json(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private static func request(_ id: String, _ method: String, _ params: [String: Any]) -> String {
        json(["id": id, "method": method, "params": params]) ?? ""
    }

    /// Runs a step; false when it fails or the tool doesn't answer in time.
    static func execute(_ step: AgentStep) -> Bool {
        let environment = ProcessInfo.processInfo.environment.filter { !terminalVariables.contains($0.key) }
        switch step {
        case .run(let cli, let arguments):
            return TerminalFocus.run(cli, arguments, environment: environment) != nil
        case .listed(let cli, let arguments, let id):
            return TerminalFocus.run(cli, arguments, environment: environment)?
                .split(separator: "\n").contains { $0.split(separator: "\t", omittingEmptySubsequences: false).first == Substring(id) } == true
        case .socket(let path, let requests):
            let replies = TerminalFocus.send(requests, toSocket: path)
            return replies.count == requests.count && replies.allSatisfy { reply in
                ((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]).map { $0["error"] == nil } ?? false
            }
        }
    }
}

/// Runs a plan off the main thread. Tests give it a runner that records the steps instead of running them.
struct AgentSender {
    var run: @Sendable ([AgentStep]) -> Bool

    static let live = AgentSender { steps in steps.allSatisfy(AgentSend.execute) }
}
