import Darwin
import Foundation

/// What is known of a process, for telling which terminal it runs in.
struct ProcessRecord: Equatable, Sendable {
    var parent: Int32
    /// Its executable's path; nil when macOS doesn't give it.
    var executable: String?
    /// Whether it has a controlling terminal.
    var hasTTY: Bool
    /// That terminal's device as Terminal.app and iTerm2 name it (`/dev/ttys003`); nil without one, or for a device of another kind.
    var tty: String? = nil
}

/// The process table as a lookup: nil for a process that is gone or is a zombie. Tests give it a made-up tree.
struct ProcessTable: Sendable {
    var lookup: @Sendable (Int32) -> ProcessRecord?

    static let live = ProcessTable { pid in
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_stat != SZOMB else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        let device = info.kp_eproc.e_tdev
        var name = [CChar](repeating: 0, count: 64)
        let tty = device != -1 && devname_r(device, S_IFCHR, &name, Int32(name.count)) != nil ? AgentInput.ttyDevice("/dev/" + String(cString: name)) : nil
        return ProcessRecord(parent: info.kp_eproc.e_ppid, executable: length > 0 ? String(cString: path) : nil,
                             hasTTY: device != -1, tty: tty)
    }
}

/// Whether the terminal a session's hook named is really the one the session runs in. The hook only reads environment
/// variables, which a child inherits: a Claude Code started from a herdr pane that was itself started from a Muxy terminal
/// carries that terminal's id, and `claude -p` run by another session (a background one, with no terminal) carries its parent's.
/// Text sent by such an id would land in a terminal the session isn't in.
struct AgentTargetCheck: Sendable {
    var processes: ProcessTable = .live
    /// The output of `muxy session list`, or nil when it fails. Takes the tool, which is run without Nunsseop's terminal variables.
    var muxyList: @Sendable (URL) -> String? = { TerminalFocus.run($0, ["session", "list"], environment: AgentSend.cleanEnvironment) }

    static let live = AgentTargetCheck()

    /// The ids of the live Muxy sessions: the first column of each line of the list. nil when the tool is missing or fails.
    func muxySessions(cli: URL?) -> Set<String>? {
        guard let cli, let listing = muxyList(cli) else { return nil }
        return Set(listing.split(separator: "\n").compactMap { $0.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init) })
    }

    /// Whether the session's process, `pid` (the hook's `$PPID`), runs in the terminal `input` names, so that text sent there
    /// reaches it. herdr's own pane list is the proof for its panes. For the others the process must be alive, have a controlling
    /// terminal (a headless child hasn't), and have the terminal's own process among its ancestors, with no other terminal app or
    /// multiplexer between them. For Muxy, `sessions` (see `muxySessions`) must also hold the id. `others` are the pids of the other
    /// sessions on the board: one among the ancestors means this is its child (an MCP server or `claude -p` that kept the parent's
    /// terminal and variables), and text sent would land in the parent's prompt.
    func verified(_ input: AgentInput, pid: Int32?, muxySessions sessions: Set<String>?, others: Set<Int32> = []) -> Bool {
        if case .muxy(let id) = input, sessions?.contains(id) != true { return false }
        return hosted(input, pid: pid, others: others)
    }

    /// The process part of `verified`, which is what can be checked right before sending.
    func hosted(_ input: AgentInput, pid: Int32?, others: Set<Int32> = []) -> Bool {
        let host: (String) -> Bool
        var tty: String?
        switch input {
        case .herdr, .paseo: return true
        case .muxy: host = Self.isMuxyServer
        case .cmux: host = Self.isCmuxApp
        case .terminalApp(let device): (host, tty) = (Self.isTerminalApp, device)
        case .iterm(let device): (host, tty) = (Self.isITerm, device)
        case .wezterm: host = Self.isWezTerm
        case .kitty: host = Self.isKitty
        case .ghostty: host = Self.isGhostty
        }
        // Terminal.app and iTerm2 find the session by its device, so the process must be on that one.
        guard let pid, let own = processes.lookup(pid), own.hasTTY, tty == nil || own.tty == tty else { return false }
        var current = pid
        var seen = Set<Int32>()
        for _ in 0..<64 {
            guard seen.insert(current).inserted, let record = processes.lookup(current) else { return false }
            // The session's own executable may sit in an app bundle; only what it runs under says which terminal it is in.
            if current != pid {
                if others.contains(current) { return false }
                if let path = record.executable {
                    if host(path) { return true }
                    if Self.isOtherTerminal(path) { return false }
                }
            }
            guard record.parent > 1 else { return false }
            current = record.parent
        }
        return false
    }

    /// The app the session's process runs under, for a hook that named none: the nearest ancestor in an app bundle (the outermost
    /// one, a helper app sits inside its main app), as its bundle id, else the bundle's name. nil when no ancestor is in one.
    func hostApp(pid: Int32) -> String? {
        var current = pid
        var seen = Set<Int32>()
        for _ in 0..<64 {
            guard seen.insert(current).inserted, let record = processes.lookup(current) else { return nil }
            if current != pid, let path = record.executable, let range = path.range(of: ".app/Contents/") {
                let bundle = String(path[..<range.lowerBound]) + ".app"
                if let id = Bundle(path: bundle)?.bundleIdentifier { return id }
                // An unreadable bundle (the app was replaced while running) must not make a terminal we can type into look unsupported.
                return Self.hostsInput(path) ? nil : ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            guard record.parent > 1 else { return nil }
            current = record.parent
        }
        return nil
    }

    /// Whether the executable is the process of a terminal that has an input API (see `AgentRow.inputApps`).
    static func hostsInput(_ path: String) -> Bool {
        isMuxyServer(path) || isCmuxApp(path) || isTerminalApp(path) || isITerm(path) || isWezTerm(path) || isKitty(path) || isGhostty(path)
    }

    /// Muxy's server, the parent of its terminals' shells: `Muxy.app/Contents/MacOS/muxy-server`.
    static func isMuxyServer(_ path: String) -> Bool { path.hasSuffix("/Muxy.app/Contents/MacOS/muxy-server") }

    /// Terminal.app, which its tabs' `login` processes run under.
    static func isTerminalApp(_ path: String) -> Bool { path == "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal" }

    /// iTerm2's app, or its `iTermServer-<version>`, which runs the shells and outlives the app (it is then a child of launchd). It runs
    /// from `~/Library/Application Support/iTerm2/` as well as from the app bundle, so a server is taken at either place.
    static func isITerm(_ path: String) -> Bool {
        path.hasSuffix("/iTerm.app/Contents/MacOS/iTerm2")
            || (isITermServer(path) && (path.contains("/iTerm.app/Contents/MacOS/") || path.contains("/Application Support/iTerm2/")))
    }

    /// A file named `iTermServer…`, wherever it sits.
    private static func isITermServer(_ path: String) -> Bool { (path as NSString).lastPathComponent.hasPrefix("iTermServer") }

    /// WezTerm's window process, or its mux server: the parents of the shells in its panes.
    static func isWezTerm(_ path: String) -> Bool { ["wezterm-gui", "wezterm-mux-server"].contains((path as NSString).lastPathComponent) }

    /// kitty, which runs the shells of its windows itself.
    static func isKitty(_ path: String) -> Bool { (path as NSString).lastPathComponent == "kitty" }

    /// Ghostty, which runs its terminals' shells itself (through `/usr/bin/login`); one app bundle named Ghostty.
    static func isGhostty(_ path: String) -> Bool { path.hasSuffix("/Ghostty.app/Contents/MacOS/ghostty") }

    /// cmux's app, which its terminals' shells run under: the executable in the `Contents/MacOS` of an app bundle named cmux.
    static func isCmuxApp(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let app = parts.lastIndex(where: { $0.hasSuffix(".app") }), parts.count > app + 2 else { return false }
        return parts[app].lowercased().hasPrefix("cmux") && parts[app + 1] == "Contents" && parts[app + 2] == "MacOS"
    }

    /// A process that is some other terminal or multiplexer: anything in an app bundle (Ghostty, Terminal, iTerm, cmux...) or a
    /// multiplexer or emulator that isn't one. A session whose chain meets one before its own terminal's process runs in that one.
    static func isOtherTerminal(_ path: String) -> Bool {
        path.contains(".app/Contents/") || isITermServer(path) || ["herdr", "tmux", "zellij", "screen", "wezterm", "wezterm-gui", "alacritty", "kitty", "ghostty"]
            .contains((path as NSString).lastPathComponent.lowercased())
    }
}
