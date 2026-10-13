import AppKit
import Network

/// Adds new screenshots to the shelf as they are saved.
@MainActor
final class ScreenshotWatcher {
    var onScreenshot: ((URL) -> Void)?
    var isEnabled = true

    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []
    private let startedAt = Date()

    static var directory: URL {
        let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let path = (configured.map { ($0 as NSString).expandingTildeInPath }) ?? ""
        if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func start() {
        let directory = Self.directory
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scan(directory)
                // The screenshot marker can land a moment after the file appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.scan(directory) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func scan(_ directory: URL) {
        guard isEnabled else { return }
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        for url in files where !seen.contains(url.path) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let created = values.creationDate, created > startedAt,
                  ["png", "jpg", "jpeg", "heic", "mov"].contains(url.pathExtension.lowercased()),
                  Self.looksLikeScreenshot(url) else { continue }
            seen.insert(url.path)
            onScreenshot?(url)
        }
    }

    /// macOS marks its screenshots with this extended attribute regardless of language.
    private static func looksLikeScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }
}

/// Shows the Caps Lock state whenever it changes.
@MainActor
final class CapsLockWatcher {
    var onChange: ((Bool) -> Void)?
    private var timer: Timer?
    private var last = NSEvent.modifierFlags.contains(.capsLock)

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func start() {
        guard timer == nil else { return }
        last = NSEvent.modifierFlags.contains(.capsLock)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = NSEvent.modifierFlags.contains(.capsLock)
                if now != self.last {
                    self.last = now
                    self.onChange?(now)
                }
            }
        }
        timer?.tolerance = 0.025
    }
}

/// What an agent's hook said happened to one session, for the agents count.
enum AgentAction: Equatable {
    /// A turn started.
    case working
    /// Asking for permission or an answer.
    case needsInput
    /// A turn ended.
    case finished
    /// Waiting at the prompt: a turn that was cut short no longer works and nothing is being asked, but a finished hand stays.
    case idle
    /// A session started, or was resumed, cleared or compacted: listed as idle when not yet known, otherwise unchanged.
    case opened
    /// The session is over.
    case remove
}

/// The tools whose sessions the agents count and the Agents tab list. Each keeps its sessions apart from the others'. The raw
/// value is what `X-Agent` carries; Claude Code's own hook sends none.
enum AgentKind: String, CaseIterable {
    case claude, codex
    /// pi and the forks that share its session files and extension API (see `PiSessions`), and gajae-code, which has no extension.
    case pi, omp, gjc, omo
    case opencode
}

/// One hook call (or extension or plugin event) from a session of one of the tools, reduced to what the count needs.
struct AgentEvent: Equatable {
    let session: String
    let action: AgentAction
    /// The bundle id of the app the session runs in.
    var app: String?
    /// Whether it runs in a herdr pane, which herdr's own count covers.
    var inHerdr = false
    var agent = AgentKind.claude
    /// The tool's own process, to tell when it is gone.
    var pid: Int32?
    /// The input API of the terminal it runs in, when the hook says one.
    var input: AgentInput?
    /// Whether it runs inside tmux, zellij or screen (`X-Mux`), which no input API reaches.
    var inMultiplexer = false
}

/// The tools' hook events as the agents count reads them. The extension of the pi family and the OpenCode plugin send the same names.
enum AgentHook {
    /// What an event means; nil for the ones that say nothing about work (`auth_success`, `SubagentStop`).
    /// `PermissionRequest` and `Interrupt` are Codex's.
    static func action(event: String, type: String?) -> AgentAction? {
        switch event {
        case "UserPromptSubmit": return .working
        case "Stop", "StopFailure": return .finished
        case "SessionEnd": return .remove
        case "SessionStart": return .opened
        case "PermissionRequest": return .needsInput
        case "Interrupt": return .idle
        case "Notification":
            switch type {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return .needsInput
            case "idle_prompt": return .idle
            case "elicitation_response", "elicitation_complete": return .working
            default: return nil
            }
        default: return nil
        }
    }

    /// The event a request's headers describe. The hook already trims its values; anything outside the
    /// whitelist is refused here as well. A call from a subagent (`X-Subagent`) is the main session's business.
    /// A background session (`X-Background`, from `claude --bg`) runs in Claude Code's daemon, so the app and the herdr
    /// pane it seems to be in are only the daemon's, inherited from wherever it was first started, and its process may
    /// be one the daemon shares with other sessions.
    static func event(headers: [String: String], processes: ProcessTable = .live) -> AgentEvent? {
        let word = { (name: String) -> String? in
            guard let value = headers[name], !value.isEmpty, value.count <= 64,
                  value.unicodeScalars.allSatisfy(CharacterSet.agentIDCharacters.contains) else { return nil }
            return value
        }
        // Claude Code's hook sends no X-Agent; a name that isn't a tool's is refused, not taken for Claude Code.
        let named = headers["x-agent"] ?? ""
        guard let agent = named.isEmpty ? AgentKind.claude : AgentKind(rawValue: named),
              headers["x-subagent"]?.isEmpty ?? true,
              let session = word("x-session"), let name = word("x-event"),
              let action = action(event: name, type: word("x-type")) else { return nil }
        let background = headers["x-background"]?.isEmpty == false
        let app = background ? nil : headers["x-app"].flatMap { value in
            !value.isEmpty && value.count <= 80 && value.unicodeScalars.allSatisfy(CharacterSet.bundleIDCharacters.contains)
                ? value : nil
        }
        let inHerdr = !background && headers["x-herdr"]?.isEmpty == false
        let inMultiplexer = headers["x-mux"]?.isEmpty == false
        let pid = background ? nil : pid(headers["x-pid"])
        let target = background || inHerdr || inMultiplexer ? nil : input(
            muxy: headers["x-muxy"], cmux: headers["x-cmux"], wezterm: headers["x-wezterm"], weztermSocket: headers["x-wezterm-socket"],
            kitty: headers["x-kitty"], kittySocket: headers["x-kitty-socket"], iterm: headers["x-iterm"], app: app,
            tty: { pid.flatMap { processes.lookup($0)?.tty } },
            hosted: { AgentTargetCheck(processes: processes).hosted($0, pid: pid) })
        return AgentEvent(session: session, action: action, app: app, inHerdr: inHerdr, agent: agent, pid: pid, input: target,
                          inMultiplexer: inMultiplexer)
    }

    /// Where text for the session can go. Muxy before cmux: a Muxy session started from a cmux terminal inherits its variables
    /// too; they come before WezTerm, kitty, iTerm2 and Terminal for the same reason. Of those the first whose terminal the session's
    /// process tree is really in (`hosted`) is taken, so a kitty started from a WezTerm shell, which has both terminals' variables,
    /// is told from the one it runs in; when none is, the first is kept and the check of the process tree (`AgentTargetCheck`)
    /// refuses it later. Terminal.app and iTerm2 export nothing a hook could use as an address, so they are told by the app
    /// (`X-App`) and addressed by the device of the session's process; iTerm2 also needs its session id.
    /// Not for a session in a herdr pane, tmux, zellij or screen, or a background one: the variables are those of the
    /// terminal around the multiplexer, or of the daemon, and text typed there reaches whichever pane is active, not the session.
    static func input(muxy: String?, cmux: String?, wezterm: String? = nil, weztermSocket: String? = nil, kitty: String? = nil,
                      kittySocket: String? = nil, iterm: String? = nil, app: String? = nil, tty: () -> String? = { nil },
                      hosted: (AgentInput) -> Bool = { _ in true }) -> AgentInput? {
        if let session = AgentInput.muxySession(muxy) { return .muxy(session) }
        if let surface = AgentInput.cmuxSurface(cmux) { return .cmux(surface) }
        var candidates: [AgentInput] = []
        if let pane = AgentInput.numericID(wezterm), let socket = AgentInput.weztermSocket(weztermSocket) { candidates.append(.wezterm(pane: pane, socket: socket)) }
        if let window = AgentInput.numericID(kitty), let socket = AgentInput.kittySocket(kittySocket) { candidates.append(.kitty(window: window, socket: socket)) }
        if app == TerminalScripts.itermID, AgentInput.itermSession(iterm) != nil, let device = AgentInput.ttyDevice(tty()) { candidates.append(.iterm(tty: device)) }
        if app == TerminalScripts.terminalID, let device = AgentInput.ttyDevice(tty()) { candidates.append(.terminalApp(tty: device)) }
        return candidates.first(where: hosted) ?? candidates.first
    }

    /// The target for a session whose hook named none, from the variables of its own process (see `ProcessEnvironment`): the same
    /// parsers, priority and `hosted` check as the hook's headers. A herdr pane, tmux, zellij or screen means none, as `X-Herdr` and
    /// `X-Mux` do.
    static func input(environment: [String: String], app: String?, tty: () -> String? = { nil },
                      hosted: (AgentInput) -> Bool = { _ in true }) -> AgentInput? {
        guard !inMultiplexer(environment: environment), environment["HERDR_PANE_ID"]?.isEmpty != false else { return nil }
        return input(muxy: environment["MUXY_SESSION_ID"], cmux: environment["CMUX_SURFACE_ID"],
                     wezterm: environment["WEZTERM_PANE"], weztermSocket: environment["WEZTERM_UNIX_SOCKET"],
                     kitty: environment["KITTY_WINDOW_ID"], kittySocket: environment["KITTY_LISTEN_ON"],
                     iterm: environment["ITERM_SESSION_ID"], app: app, tty: tty, hosted: hosted)
    }

    /// Whether a process's own variables say it runs in tmux, zellij or screen, as `X-Mux` does.
    static func inMultiplexer(environment: [String: String]) -> Bool {
        ["TMUX", "ZELLIJ", "STY"].contains { environment[$0]?.isEmpty == false }
    }

    /// A process id from `X-Pid`: ASCII digits only, up to 10 of them, past 1 (init) and no more than a `pid_t` holds.
    static func pid(_ value: String?) -> Int32? {
        guard let value, (1...10).contains(value.utf8.count), value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let pid = Int32(value), pid > 1 else { return nil }
        return pid
    }
}

/// Accepts notifications from local tools such as Claude Code hooks:
/// `POST http://127.0.0.1:47750/notify` with `Authorization: Bearer <token>` and a JSON body
/// `{"title": "...", "message": "..."}`. The token lives in Application Support/Nunsseop/notify-token; the same header, as
/// one line, in notify-auth beside it. The commands below give curl that file (`-H @file`) instead of the token, so the
/// notify token is in no argument list, which `ps` would show to every user. It does go to whatever listens on the port,
/// so a stranger who binds 47750 while Nunsseop is off can learn it and fake notices, and nothing more: it authenticates
/// `/notify` and `/agent` only. Prompts are answered under the permission key (permission-key), which is never sent.
/// `POST /agent` takes the tools' session events for the agents count, as headers only (see `agentHookCommand`, `PiExtension`, `OpenCodePlugin`).
/// `POST /permission` holds a permission prompt (Claude Code's, Codex's or OpenCode's) until it is answered in the notch (see `PermissionGate`).
final class NotifyServer: @unchecked Sendable {
    static let port: UInt16 = 47750
    /// A notification a local tool sent, with where it came from when the tool said so.
    struct Notice {
        let title: String
        let message: String?
        /// The bundle id of the app the tool ran in (its terminal), from macOS's `__CFBundleIdentifier`.
        var app: String?
        /// A pane in a terminal, as `tmux:%12` or `WezTerm:7`.
        var target: String?
    }

    var onNotify: (@MainActor (Notice) -> Void)?
    var onAgent: (@MainActor (AgentEvent) -> Void)?

    private let listenPort: UInt16
    private let queue: DispatchQueue
    /// Touched only on `queue`.
    private var listener: NWListener?
    private var retry: DispatchWorkItem?
    private var retryDelay = NotifyServer.firstRetryDelay
    /// Touched only on `queue`.
    private var boundPort: UInt16?
    /// The connections counted against `maxConnections`; one that becomes a held prompt leaves it.
    private var ordinary = Set<ObjectIdentifier>()
    private static let firstRetryDelay = 1.0
    private static let lastRetryDelay = 4.0
    private static let maxConnections = 8
    static let maxRequestBytes = 65_536
    let token: String
    /// What `/permission` is proven with, apart from `token`. Never sent: only HMACs made with it are.
    let permissionKey: String
    let permissions: PermissionGate

    /// A shell command for Claude Code's Notification hook. Claude Code passes the event as
    /// JSON on stdin; its `message` field is sent as the notification text.
    static var hookCommand: String { hookCommand(title: "Claude Code") }

    /// What every command gives curl in place of `-H "Authorization: Bearer <token>"`: the path of the file holding that
    /// one header line (curl reads headers from `-H @file` since 7.55), so no command line ever holds the token.
    static let authHeaderOption = "-H @\"$HOME/Library/Application Support/Nunsseop/notify-auth\""

    /// The same command for any tool that passes JSON with a `message` field on stdin, such as Gemini CLI.
    static func hookCommand(title: String, port: UInt16 = NotifyServer.port) -> String {
        "plutil -extract message raw -o - - 2>/dev/null | curl -s -m 2 -X POST http://127.0.0.1:\(port)/notify "
            + authHeaderOption + " "
            + "-H 'X-Title: \(title)' -H \"X-App: $__CFBundleIdentifier\" -H \"X-Background: ${CLAUDE_JOB_DIR:+1}\" --data-binary @- >/dev/null || true"
    }

    /// Claude Code's hook for the agents count, the same for every event. Claude Code passes the event as JSON on
    /// stdin; only the ids and names below leave it, as headers (no prompt, reply, folder or transcript), trimmed to
    /// safe characters so a stray newline can't break one. `$PPID` is the `claude` process itself (the same is assumed for
    /// Codex, whose hook runs under it the same way; not checkable without running Codex), whose end tells that a session is
    /// gone and whose terminal `AgentTargetCheck` looks up. `X-Muxy`, `X-Cmux`, `X-Wezterm` (with `X-Wezterm-Socket`), `X-Kitty` (with `X-Kitty-Socket`) and
    /// `X-Iterm` carry the ids of the terminal it runs in (empty when it isn't in one), which `AgentHook.event` checks again before they say where to type; `X-Mux` says it runs
    /// inside tmux, zellij or screen.
    /// Nothing may reach stdout, which `UserPromptSubmit` and `SessionStart` add to Claude's context, and a closed or stuck
    /// Nunsseop costs a session at most a second.
    static var agentHookCommand: String { agentHookCommand(for: .claude) }

    /// The same hook for Codex, which passes the same fields and adds `X-Agent` so its sessions stay apart from
    /// Claude Code's. Codex asks to trust a hook again when its command changes, so this text shouldn't change lightly.
    static func agentHookCommand(for agent: AgentKind, port: UInt16 = NotifyServer.port) -> String {
        "in=$(cat); k() { printf '%s' \"$in\" | plutil -extract \"$1\" raw -o - - 2>/dev/null | tr -cd 'A-Za-z0-9_.-' | cut -c1-64; }; "
            + "curl -s -m 1 --connect-timeout 1 -X POST http://127.0.0.1:\(port)/agent -d '' "
            + authHeaderOption + " "
            + "-H \"X-Session: $(k session_id)\" -H \"X-Event: $(k hook_event_name)\" -H \"X-Type: $(k notification_type)\" "
            + "-H \"X-Subagent: $(k agent_id)\" -H \"X-App: $__CFBundleIdentifier\" -H \"X-Herdr: ${HERDR_PANE_ID:+1}\" "
            + "-H \"X-Muxy: ${MUXY_SESSION_ID}\" -H \"X-Cmux: ${CMUX_SURFACE_ID}\" "
            + "-H \"X-Mux: ${TMUX:+1}${ZELLIJ:+1}${STY:+1}\" "
            + "-H \"X-Wezterm: ${WEZTERM_PANE}\" -H \"X-Wezterm-Socket: ${WEZTERM_UNIX_SOCKET}\" -H \"X-Kitty: ${KITTY_WINDOW_ID}\" -H \"X-Kitty-Socket: ${KITTY_LISTEN_ON}\" "
            + "-H \"X-Iterm: ${ITERM_SESSION_ID}\" "
            + "-H \"X-Background: ${CLAUDE_JOB_DIR:+1}\" "
            + "-H \"X-Pid: $PPID\" "
            + (agent == .claude ? "" : "-H 'X-Agent: \(agent.rawValue)' ")
            + ">/dev/null 2>&1 || true"
    }

    /// Claude Code's PermissionRequest hook. It asks the notch about a permission prompt and prints the answer Claude Code
    /// reads from stdout, or nothing at all, which leaves the terminal's dialog in charge: that is what every failure ends in.
    ///
    /// The permission key (not the notify token) is read by redirection into `tr`, which has no argument holding it, and
    /// goes no further than shell variables, so it is in no process's arguments (`ps` shows those to every user). It is
    /// not sent either: the request carries an HMAC-SHA256 of a fresh nonce and the body, built from `openssl dgst` calls
    /// over the key XOR the HMAC pads, which reach it on stdin (see `PermissionWire`). An answer is printed only when its
    /// own HMAC, over the same nonce and the exact bytes printed, checks out. A stranger on 127.0.0.1:47750 can learn the
    /// notify token from a notice hook, but that is not the key, so it can't make the hook allow anything.
    /// The answer is held in a shell variable, so nothing of the prompt reaches a file. When Claude Code ends the hook (the
    /// terminal answered first) by TERM or KILL, a watchdog sees the shell gone within a second and ends curl and its connection.
    static var permissionHookCommand: String { permissionHookCommand(port: port) }

    static func permissionHookCommand(port: UInt16) -> String {
        #"""
        t="$HOME/Library/Application Support/Nunsseop/permission-key"
        in=$(cat)
        [ -n "$in" ] && [ $(printf %s "$in" | wc -c) -le \#(PermissionGate.maxBodyBytes) ] || exit 0
        kh=$(tr -d ' \t\r\n' < "$t" 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
        [ ${#kh} -ge 64 ] || exit 0
        [ ${#kh} -gt 128 ] && kh=$(tr -d ' \t\r\n' < "$t" | openssl dgst -sha256 -binary | od -An -v -tx1 | tr -d ' \n')
        while [ ${#kh} -lt 128 ]; do kh=${kh}00; done
        i=; o=; r=$kh
        while [ -n "$r" ]; do h=${r%"${r#??}"}; r=${r#??}; v=$((0x$h)); x=$((v ^ 54)); i="$i\\$((x >> 6))$(((x >> 3) & 7))$((x & 7))"; x=$((v ^ 92)); o="$o\\$((x >> 6))$(((x >> 3) & 7))$((x & 7))"; done
        H() { openssl dgst -sha256 | sed 's/^.*= //'; }
        M() { { printf "$i"; cat; } | openssl dgst -sha256 -binary | { printf "$o"; cat; } | H; }
        n=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
        [ ${#n} -eq 32 ] || exit 0
        p=$(printf 'nunsseop-permission-request\n%s\n%s' "$n" "$(printf %s "$in" | H)" | M)
        s=$$
        r=$({ printf %s "$in" | curl -s -m 590 --connect-timeout 1 -X POST http://127.0.0.1:\#(port)/permission -H 'Expect:' -H "X-Nonce: $n" -H "X-Proof: $p" --data-binary @- 2>/dev/null &
        c=$!
        ( while kill -0 $s 2>/dev/null; do kill -0 $c 2>/dev/null || exit 0; sleep 1; done; kill $c ) >/dev/null 2>&1 &
        wait $c; })
        case $r in *\ *) ;; *) exit 0;; esac
        m=${r%% *}
        d=${r#* }
        [ -n "$d" ] && [ "$m" = "$(printf 'nunsseop-permission-response\n%s\n%s' "$n" "$(printf %s "$d" | H)" | M)" ] && printf %s "$d"
        exit 0
        """#
    }

    /// A command for scripts: the text after `--data-binary` becomes the notification.
    static var scriptCommand: String { scriptCommand(port: port) }

    static func scriptCommand(port: UInt16) -> String {
        "curl -s -m 2 -X POST http://127.0.0.1:\(port)/notify " + authHeaderOption + " "
            + "-H 'X-Title: Script' --data-binary 'Done'"
    }

    static var tokenURL: URL {
        (NotifyIntegration.homeOverride?.appendingPathComponent("Library/Application Support")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Nunsseop/notify-token")
    }

    /// The file with the `Authorization` header line the commands give curl (`-H @file`), beside the token.
    static var authHeaderURL: URL { tokenURL.deletingLastPathComponent().appendingPathComponent("notify-auth") }

    /// The key the permission hook and `PermissionGate` prove themselves with, beside the token.
    static var permissionKeyURL: URL { tokenURL.deletingLastPathComponent().appendingPathComponent("permission-key") }

    /// Makes the header file say what the token file does. A missing, stale or loosely held one is replaced; it holds
    /// the token as much as the token file does, so it is private as well. Does nothing without a usable token file.
    static func syncAuthHeader() {
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              token.count >= 32 else { return }
        let line = "Authorization: Bearer \(token)\n"
        let url = authHeaderURL
        if (try? String(contentsOf: url, encoding: .utf8)) == line {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            SecretFiles.write(line, to: url)
        }
    }

    /// The secret in `url` when it is a usable one (32 characters or more, whitespace around it ignored; the file is made
    /// private if it wasn't), otherwise a new random one, written private from its first byte.
    private static func loadOrCreateSecret(at url: URL) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return existing
        }
        let secret = SecretFiles.randomHex()
        SecretFiles.write(secret, to: url)
        return secret
    }

    init(port: UInt16 = NotifyServer.port, permissionHold: Double = PermissionGate.holdSeconds) {
        listenPort = port
        let queue = DispatchQueue(label: "nunsseop.notify")
        self.queue = queue
        // The folder holding the secrets is for this user alone, whatever it was when an earlier version made it.
        SecretFiles.makeDirectoryPrivate(Self.tokenURL.deletingLastPathComponent())
        token = Self.loadOrCreateSecret(at: Self.tokenURL)
        permissionKey = Self.loadOrCreateSecret(at: Self.permissionKeyURL)
        Self.syncAuthHeader()
        permissions = PermissionGate(key: permissionKey, queue: queue, holdSeconds: permissionHold)
    }

    /// The port the listener is ready on, nil until it is; with port 0 the system picks it.
    var listeningPort: UInt16? { queue.sync { boundPort } }

    func start() {
        queue.sync {
            guard listener == nil, retry == nil else { return }
            listen()
        }
    }

    func stop() {
        queue.sync {
            retry?.cancel()
            retry = nil
            retryDelay = Self.firstRetryDelay
            listener?.cancel()
            listener = nil
            boundPort = nil
            permissions.releaseAll()
        }
    }

    /// Runs on `queue`. The port can still be held when the app starts, by sockets of the previous run in TIME_WAIT: the
    /// listener then fails with EADDRINUSE and stays failed, so it is replaced after a delay until one is ready.
    private func listen() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: listenPort)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                retryDelay = Self.firstRetryDelay
                boundPort = listener.port?.rawValue
            case .failed:
                listener.cancel()
                self.listener = nil
                boundPort = nil
                let work = DispatchWorkItem { [weak self] in
                    self?.retry = nil
                    self?.listen()
                }
                retry = work
                queue.asyncAfter(deadline: .now() + retryDelay, execute: work)
                retryDelay = min(retryDelay * 2, Self.lastRetryDelay)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        guard ordinary.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        ordinary.insert(id)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.ordinary.remove(id)
            default: break
            }
        }
        connection.start(queue: queue)
        // Drop clients that connect and then stall; a held prompt is meant to wait.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.permissions.holds(connection) != true { connection.cancel() }
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.respond(to: request, on: connection)
            } else if Self.declaresTooMuch(buffer) {
                self.reply(connection, status: "413 Payload Too Large")
            } else if isComplete || error != nil || buffer.count > Self.bufferLimit(buffer) {
                self.reply(connection, status: "400 Bad Request")
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// What a request may hold before it is refused: a prompt's body is the hook's whole input, which can be a large file.
    static func requestLimit(path: String) -> Int {
        path == "/permission" ? PermissionGate.maxBodyBytes : maxRequestBytes
    }

    private static func bufferLimit(_ buffer: Data) -> Int {
        buffer.starts(with: Data("POST /permission ".utf8)) ? PermissionGate.maxBodyBytes + 16_384 : maxRequestBytes
    }

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func head(of data: Data) -> (method: String, path: String, headers: [String: String], bodyStart: Data.Index)? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (String(parts[0]), String(parts[1]), headers, separator.upperBound)
    }

    static func parse(_ data: Data) -> Request? {
        guard let head = head(of: data), let length = Int(head.headers["content-length"] ?? "0"),
              (0...requestLimit(path: head.path)).contains(length) else { return nil }
        let body = data[head.bodyStart...]
        guard body.count >= length else { return nil }
        return Request(method: head.method, path: head.path, headers: head.headers, body: Data(body.prefix(length)))
    }

    /// Whether the headers already say the body will be more than the path allows, so there is no point waiting for it.
    static func declaresTooMuch(_ data: Data) -> Bool {
        guard let head = head(of: data), let length = Int(head.headers["content-length"] ?? "0") else { return false }
        return length > requestLimit(path: head.path)
    }

    /// What a request asks the app to do, once it is answered.
    enum Effect {
        case none
        case notice(Notice)
        case agent(AgentEvent)
    }

    private func respond(to request: Request, on connection: NWConnection) {
        if request.path == "/permission" {
            if permissions.accept(request, on: connection) { ordinary.remove(ObjectIdentifier(connection)) }
            return
        }
        let (status, effect) = route(request)
        switch effect {
        case .none: break
        case .agent(let event):
            let handler = onAgent
            DispatchQueue.main.async { MainActor.assumeIsolated { handler?(event) } }
        case .notice(let notice):
            let handler = onNotify
            DispatchQueue.main.async { MainActor.assumeIsolated { handler?(notice) } }
        }
        reply(connection, status: status)
    }

    func route(_ request: Request) -> (status: String, effect: Effect) {
        guard request.method == "POST", request.path == "/notify" || request.path == "/agent" else {
            return ("404 Not Found", .none)
        }
        guard Self.constantTimeEqual(request.headers["authorization"] ?? "", "Bearer \(token)") else {
            return ("401 Unauthorized", .none)
        }
        if request.path == "/agent" {
            return ("204 No Content", AgentHook.event(headers: request.headers).map(Effect.agent) ?? .none)
        }
        // The body is either JSON {"title", "message"} or plain text with the title in X-Title.
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        // Sent by tools that relay several agents (tmux): one whose own hook is connected already notifies.
        if let agent = json?["agent"] as? String ?? request.headers["x-agent"],
           NotifyIntegration.forAgent(agent)?.isInstalled == true {
            return ("204 No Content", .none)
        }
        let text = json == nil ? String(data: request.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let title = String((json?["title"] as? String ?? request.headers["x-title"] ?? "Notification").prefix(80))
        let message = (json?["message"] as? String ?? text).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        let notice = Notice(title: title, message: message,
                            app: Self.noticeApp(json: json, headers: request.headers),
                            target: Self.clean(json?["target"] as? String ?? request.headers["x-target"], .targetCharacters))
        return ("204 No Content", .notice(notice))
    }

    private static func clean(_ value: String?, _ allowed: CharacterSet) -> String? {
        guard let value, !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return String(value.prefix(80))
    }

    /// The app a notice came from. A background session (`X-Background`) has none: the app is only the daemon's.
    static func noticeApp(json: [String: Any]?, headers: [String: String]) -> String? {
        if headers["x-background"]?.isEmpty == false { return nil }
        return clean(json?["app"] as? String ?? headers["x-app"], .bundleIDCharacters)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            difference |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return difference == 0
    }

    private func reply(_ connection: NWConnection, status: String) {
        Self.reply(connection, status: status)
    }

    static func reply(_ connection: NWConnection, status: String, body: Data = Data()) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private extension CharacterSet {
    static let agentIDCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    static let bundleIDCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    static let targetCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
}
