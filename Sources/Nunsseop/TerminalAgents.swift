import AppKit
import Network

extension NotifyIntegration {
    /// The tool an agent name from a terminal app (Muxy, herdr) stands for, whose own Nunsseop hook,
    /// when connected, already sends its notifications.
    static func forAgent(_ name: String?) -> NotifyIntegration? {
        switch name?.lowercased() {
        case "claude", "claude code": .claudeCode
        case "codex": .codex
        case "gemini", "gemini cli": .gemini
        case "opencode": .openCode
        default: nil
        }
    }
}

/// Splits a byte stream into newline-delimited JSON objects.
struct JSONLines {
    private var buffer = Data()

    /// A line longer than this is no frame any of these tools sends; it's thrown away.
    static let maxLine = 1 << 20

    mutating func append(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var objects: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { objects.append(object) }
        }
        if buffer.count > Self.maxLine { buffer.removeAll() }
        return objects
    }
}

// MARK: - cmux

/// cmux's notifications, read through the `cmux` command inside the app, which finds the socket and its password.
/// The event stream leaves out titles and bodies, so each new notification is looked up in the list.
enum Cmux {
    static let bundleID = "com.cmuxterm.app"

    static var cli: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .appendingPathComponent("Contents/Resources/bin/cmux")
    }

    static var isInstalled: Bool { cli.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }

    struct Notice: Equatable {
        let title: String
        let body: String
        var id: String? = nil
    }

    /// Opens the notification in cmux (its workspace and surface, marked read) and brings cmux forward.
    static func focus(_ notice: Notice, cli: URL? = Cmux.cli) {
        guard let cli, let id = notice.id, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = TerminalFocus.run(cli, ["open-notification", "--id", id])
            DispatchQueue.main.async { TerminalFocus.activate(bundleID: bundleID) }
        }
    }

    /// The notification id of a `notification.created` event frame.
    static func createdID(in frame: [String: Any]) -> String? {
        guard frame["type"] as? String == "event", frame["name"] as? String == "notification.created" else { return nil }
        return (frame["payload"] as? [String: Any])?["notification_id"] as? String
    }

    /// The unread notification with `id` in the output of `cmux rpc notification.list`.
    static func notice(_ id: String, inList data: Data) -> Notice? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let rows = object["notifications"] as? [[String: Any]]
            ?? (object["result"] as? [String: Any])?["notifications"] as? [[String: Any]] ?? []
        guard let row = rows.first(where: { ($0["id"] as? String)?.caseInsensitiveCompare(id) == .orderedSame }),
              row["is_read"] as? Bool != true else { return nil }
        let title = row["title"] as? String ?? "cmux"
        let subtitle = row["subtitle"] as? String ?? ""
        let body = row["body"] as? String ?? ""
        return Notice(title: title, body: [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · "),
                      id: row["id"] as? String)
    }
}

@MainActor
final class CmuxWatcher {
    var onNotice: ((Cmux.Notice) -> Void)?
    /// Looked up on every launch, so a cmux installed later is found.
    private let findCLI: () -> URL?
    private let retryDelay: TimeInterval
    private var cli: URL?
    /// Launch attempts, for tests.
    private(set) var launches = 0
    private var stream: Process?
    private var lines = JSONLines()
    private var running = false
    /// Bumped on every start and stop, so a retry scheduled before them doesn't run as well as a new one.
    private var generation = 0
    private var quitObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "nunsseop.cmux")

    init(findCLI: @escaping () -> URL? = { Cmux.cli }, retryDelay: TimeInterval = 30) {
        self.findCLI = findCLI
        self.retryDelay = retryDelay
    }

    /// A fixed command, for tests.
    convenience init(cli: URL) { self.init(findCLI: { cli }) }

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        // The event stream is a child process, which would outlive Nunsseop otherwise.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        launch()
    }

    func stop() {
        running = false
        generation += 1
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        if stream?.isRunning == true { stream?.terminate() }
        stream = nil
        lines = JSONLines()
    }

    /// Tries again after a pause, when the command couldn't start or stopped on its own.
    private func relaunch(after process: Process?) {
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == generation, self.stream === process else { return }
                self.stream = nil
                self.lines = JSONLines()
                self.launch()
            }
        }
    }

    private func launch() {
        guard running, stream == nil else { return }
        launches += 1
        cli = findCLI()
        // Not installed (yet): looked for again after the pause.
        guard let cli else { return relaunch(after: nil) }
        let process = Process()
        process.executableURL = cli
        // --reconnect keeps waiting while cmux isn't running and resumes after it restarts.
        process.arguments = ["events", "--name", "notification.created", "--reconnect", "--no-ack", "--no-heartbeat"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty means the end of the output; without this the handler keeps firing.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.relaunch(after: process) } }
        }
        stream = process
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            relaunch(after: process)
        }
    }

    private func received(_ data: Data) {
        for frame in lines.append(data) {
            if let id = Cmux.createdID(in: frame) { lookUp(id) }
        }
    }

    private func lookUp(_ id: String) {
        guard let cli else { return }
        queue.async { [weak self] in
            let process = Process()
            process.executableURL = cli
            process.arguments = ["rpc", "notification.list"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            // A cmux that doesn't answer mustn't hold up the lookups after it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let notice = Cmux.notice(id, inList: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // cmux shows the notification itself while it's in front.
                    guard let self, self.running,
                          NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Cmux.bundleID,
                          NotifyIntegration.forAgent(notice.title)?.isInstalled != true else { return }
                    self.onNotice?(notice)
                }
            }
        }
    }
}

// MARK: - herdr

/// herdr's socket API: newline-delimited JSON over `~/.config/herdr/herdr.sock`. Agent states are
/// subscribed per pane, so the subscription is renewed whenever panes come and go.
enum Herdr {
    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr/herdr.sock")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: socketURL.deletingLastPathComponent().path)
    }

    /// The default session's socket, then one per named session (`herdr --session <name>`), which live at
    /// `sessions/<name>/herdr.sock` beside it. The default is listed even before its server first runs.
    static func sockets(in config: URL = socketURL.deletingLastPathComponent()) -> [(session: String?, url: URL)] {
        let sessions = config.appendingPathComponent("sessions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        let named = names.sorted().compactMap { name -> (session: String?, url: URL)? in
            let url = sessions.appendingPathComponent(name).appendingPathComponent("herdr.sock")
            return FileManager.default.fileExists(atPath: url.path) ? (name, url) : nil
        }
        return [(nil, config.appendingPathComponent("herdr.sock"))] + named
    }

    struct Pane: Equatable {
        let id: String
        let status: String
        var agent: String? = nil
        var title: String? = nil
        /// The folder the agent's process is in, and the agent's own session id when herdr knows it.
        var cwd: String? = nil
        var session: String? = nil
    }

    /// An agent in a pane that just finished or is waiting for the user.
    struct Notice: Equatable {
        let agent: String
        let status: String
        let title: String?
        /// Where it came from, to go back there.
        var pane: String? = nil
        var socket: URL? = nil
    }

    /// Focuses the pane in herdr and brings forward the terminal app herdr's client runs in.
    static func focus(_ notice: Notice) {
        guard let pane = notice.pane, let socket = notice.socket else { return }
        focus(pane: pane, socket: socket)
    }

    static func focus(pane: String, socket: URL) {
        let request = String(decoding: Herdr.request("focus", "pane.focus", ["pane_id": pane]).dropLast(), as: UTF8.self)
        DispatchQueue.global(qos: .userInitiated).async {
            TerminalFocus.send([request], toSocket: socket.path)
            let clients = TerminalFocus.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-x", "herdr"]) ?? ""
            let pids = clients.split(separator: "\n").compactMap { pid_t($0) }
            DispatchQueue.main.async {
                pids.lazy.compactMap(TerminalFocus.hostingApp(of:)).first.map(TerminalFocus.activate)
            }
        }
    }

    static func request(_ id: String, _ method: String, _ params: [String: Any] = [:]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Pane lifecycle plus the agent state of every listed pane.
    static func subscription(_ id: String, panes: [Pane]) -> Data {
        let lifecycle: [[String: Any]] = [["type": "pane.created"], ["type": "pane.closed"]]
        let states: [[String: Any]] = panes.map { ["type": "pane.agent_status_changed", "pane_id": $0.id] }
        return request(id, "events.subscribe", ["subscriptions": lifecycle + states])
    }

    /// The panes in a `pane.list` response.
    static func panes(in response: [String: Any]) -> [Pane]? {
        guard let rows = (response["result"] as? [String: Any])?["panes"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            (row["pane_id"] as? String).map {
                let session = row["agent_session"] as? [String: Any]
                return Pane(id: $0, status: row["agent_status"] as? String ?? "unknown",
                            agent: row["display_agent"] as? String ?? row["agent"] as? String, title: row["title"] as? String,
                            cwd: row["foreground_cwd"] as? String ?? row["cwd"] as? String,
                            session: session?["kind"] as? String == "id" ? session?["value"] as? String : nil)
            }
        }
    }

    enum Event: Equatable {
        case panesChanged
        case status(pane: String, Notice)
    }

    static func event(in frame: [String: Any]) -> Event? {
        let data = frame["data"] as? [String: Any] ?? [:]
        switch frame["event"] as? String {
        case "pane.created", "pane.closed":
            return .panesChanged
        case "pane.agent_status_changed":
            guard let pane = data["pane_id"] as? String, let status = data["agent_status"] as? String else { return nil }
            let agent = data["display_agent"] as? String ?? data["agent"] as? String ?? "herdr"
            return .status(pane: pane, Notice(agent: agent, status: status, title: data["title"] as? String, pane: pane))
        default:
            return nil
        }
    }

    /// The last known state of each pane; only a change into `done` (finished, not yet seen) or `blocked`
    /// (waiting for the user) is announced.
    struct States {
        private(set) var byPane: [String: String] = [:]

        /// Takes a fresh pane list as the known states. Panes already known that moved into `done` or `blocked`
        /// while no subscription was listening (between two subscriptions) are returned to announce.
        mutating func reconcile(_ panes: [Pane]) -> [Pane] {
            let known = byPane
            byPane = Dictionary(panes.map { ($0.id, $0.status) }, uniquingKeysWith: { $1 })
            return panes.filter { pane in
                guard let before = known[pane.id] else { return false }
                return (pane.status == "done" || pane.status == "blocked") && before != pane.status
            }
        }

        mutating func update(pane: String, to status: String) -> Bool {
            defer { byPane[pane] = status }
            return (status == "done" || status == "blocked") && byPane[pane] != status
        }
    }
}

/// One HerdrWatcher per herdr session, following sessions as they're started and removed.
@MainActor
final class HerdrSessions {
    /// The notice, and the session it came from (nil for the default one).
    var onNotice: ((Herdr.Notice, String?) -> Void)?
    /// Every pane's state in one session, keyed by its socket; empty when that session went away.
    var onStates: ((String, [String: Herdr.PaneState]) -> Void)?
    private let config: URL
    private var watchers: [URL: HerdrWatcher] = [:]
    private var scan: Timer?

    init(config: URL = Herdr.socketURL.deletingLastPathComponent()) { self.config = config }

    func start() {
        guard scan == nil else { return }
        refresh()
        scan = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        scan?.tolerance = 2
    }

    func stop() {
        scan?.invalidate()
        scan = nil
        watchers.values.forEach { $0.stop() }
        for url in watchers.keys { onStates?(url.path, [:]) }
        watchers = [:]
    }

    private func refresh() {
        let sockets = Herdr.sockets(in: config)
        let current = Set(sockets.map(\.url))
        for (url, watcher) in watchers where !current.contains(url) {
            watcher.stop()
            watchers[url] = nil
            onStates?(url.path, [:])
        }
        for socket in sockets where watchers[socket.url] == nil {
            let watcher = HerdrWatcher(socketURL: socket.url)
            watcher.onNotice = { [weak self] notice in self?.onNotice?(notice, socket.session) }
            watcher.onStates = { [weak self] states in self?.onStates?(socket.url.path, states) }
            watcher.start()
            watchers[socket.url] = watcher
        }
    }
}

@MainActor
final class HerdrWatcher {
    var onNotice: ((Herdr.Notice) -> Void)?
    /// Every pane's state, with since when, whenever one changes; empty when the server is gone or watching stops.
    var onStates: (([String: Herdr.PaneState]) -> Void)?
    /// When each pane entered its current state, kept across reconnects. It's when Nunsseop first saw that state:
    /// after a relaunch a pane that was already done counts from then, for another `doneWindow`.
    private var since: [String: Herdr.PaneState] = [:]
    /// The agent, folder and session id each pane had in the last list.
    private var listed: [String: Herdr.Pane] = [:]
    /// Connections that waited in a row without reaching herdr, and since when it has been out of reach.
    private var misses = 0
    private var unreachableSince: Date?
    /// How long herdr may stay out of reach, and how many waits in a row, before what it said is forgotten:
    /// a socket left behind by a crashed server makes every connection wait, and its last states mustn't linger.
    static let unreachableLimit: TimeInterval = 30
    static let missLimit = 2
    private let retryInterval: TimeInterval
    private let socketURL: URL
    private var connection: NWConnection?
    private var lines = JSONLines()
    private var states = Herdr.States()
    private var retry: Timer?
    private var running = false
    private let queue = DispatchQueue(label: "nunsseop.herdr")

    init(socketURL: URL = Herdr.socketURL, retryInterval: TimeInterval = 10) {
        self.socketURL = socketURL
        self.retryInterval = retryInterval
    }

    func start() {
        guard !running else { return }
        running = true
        connect()
        // herdr's server may start later or restart; a closed connection is opened again from here.
        retry = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.connection == nil { self?.connect() } }
        }
        retry?.tolerance = 2
    }

    func stop() {
        running = false
        retry?.invalidate()
        retry = nil
        drop()
        forget()
    }

    /// Nothing is known about the panes any more (the server quit, or watching stopped).
    private func forget() {
        _ = states.reconcile([])
        since = [:]
        listed = [:]
        misses = 0
        unreachableSince = nil
        onStates?([:])
    }

    /// A connection that only waited: once it keeps happening, or has gone on too long, herdr counts as gone.
    private func missed(now: Date = .now) {
        misses += 1
        let first = unreachableSince ?? now
        unreachableSince = first
        if misses >= Self.missLimit || now.timeIntervalSince(first) >= Self.unreachableLimit { forget() }
    }

    /// Hands every pane's state on, keeping the time a pane entered its state for as long as it stays in it.
    private func publish(now: Date = .now) {
        var next: [String: Herdr.PaneState] = [:]
        for (pane, status) in states.byPane {
            var state = since[pane].flatMap { $0.status == status ? $0 : nil } ?? Herdr.PaneState(status: status, since: now)
            (state.agent, state.cwd, state.session) = (listed[pane]?.agent, listed[pane]?.cwd, listed[pane]?.session)
            next[pane] = state
        }
        since = next
        onStates?(next)
    }

    private func drop() {
        connection?.cancel()
        connection = nil
        lines = JSONLines()
    }

    /// Lists the panes on one connection, then subscribes on a new one: a subscription takes its connection over.
    private func connect() {
        guard running, connection == nil else { return }
        // No socket: the server isn't running, so nothing it said earlier still holds.
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            if !states.byPane.isEmpty { forget() }
            return
        }
        open { [weak self] frame in
            guard let self, frame["id"] as? String == "list" else { return }
            self.drop()
            guard let panes = Herdr.panes(in: frame) else { return }
            // Reached herdr again.
            self.misses = 0
            self.unreachableSince = nil
            self.listed = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            for pane in self.states.reconcile(panes) {
                self.announce(Herdr.Notice(agent: pane.agent ?? "herdr", status: pane.status, title: pane.title, pane: pane.id))
            }
            self.publish()
            self.open(sending: Herdr.subscription("sub", panes: panes)) { [weak self] frame in self?.handle(frame) }
        }
        connection?.send(content: Herdr.request("list", "pane.list"), completion: .contentProcessed { _ in })
    }

    private func open(sending first: Data? = nil, _ onFrame: @escaping (([String: Any]) -> Void)) {
        let connection = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            // A socket left behind by a server that quit can leave the connection waiting for good.
            case .failed, .cancelled, .waiting:
                // A connection only waiting (a hiccup) keeps what's known, so the list after reconnecting still
                // announces what changed meanwhile, unless the waits repeat or last (`missed`); one that failed
                // means the server is gone.
                let gone = { if case .waiting = state { return false } else { return true } }()
                DispatchQueue.main.async {
                    // Only a connection that failed on its own; replaced ones are cancelled on purpose.
                    MainActor.assumeIsolated {
                        if self?.connection === connection {
                            self?.drop()
                            if gone { self?.forget() } else { self?.missed() }
                        }
                    }
                }
            default: break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
        if let first { connection.send(content: first, completion: .contentProcessed { _ in }) }
        receive(on: connection, onFrame)
    }

    private func receive(on connection: NWConnection, _ onFrame: @escaping (([String: Any]) -> Void)) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.connection === connection else { return }
                    // Frames after one that moved on to a new connection belong to the old one.
                    for frame in self.lines.append(data ?? Data()) where self.connection === connection { onFrame(frame) }
                    // A frame may have moved on to a new connection; only this one is dropped or read further.
                    guard self.connection === connection else { return }
                    if isComplete || error != nil {
                        self.drop()
                    } else {
                        self.receive(on: connection, onFrame)
                    }
                }
            }
        }
    }

    private func handle(_ frame: [String: Any]) {
        // Subscribed: states that changed between the pane list and now are caught up from a second list.
        if frame["id"] as? String == "sub", frame["result"] != nil { return relist() }
        switch Herdr.event(in: frame) {
        case .panesChanged:
            // Subscribe again with the new pane list.
            drop()
            connect()
        case .status(let pane, let notice):
            if states.update(pane: pane, to: notice.status) { announce(notice) }
            publish()
        case nil:
            // A rejected subscription (a pane closed meanwhile): the timer subscribes again with a fresh list.
            if frame["error"] != nil { drop() }
        }
    }

    private func relist() {
        let socket = socketURL.path
        let request = String(decoding: Herdr.request("relist", "pane.list").dropLast(), as: UTF8.self)
        queue.async { [weak self] in
            guard let reply = TerminalFocus.send([request], toSocket: socket).first,
                  let frame = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
                  let panes = Herdr.panes(in: frame) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.listed = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                    for pane in self.states.reconcile(panes) {
                        self.announce(Herdr.Notice(agent: pane.agent ?? "herdr", status: pane.status, title: pane.title, pane: pane.id))
                    }
                    self.publish()
                }
            }
        }
    }

    private func announce(_ notice: Herdr.Notice) {
        guard NotifyIntegration.forAgent(notice.agent)?.isInstalled != true else { return }
        var notice = notice
        notice.socket = socketURL
        onNotice?(notice)
    }
}

// MARK: - Terminal bells

/// The script terminals run when a pane rings the bell (tmux through a hook, WezTerm from its config).
/// Arguments: the terminal's name, where the pane is (session or workspace), its window or title, the running
/// command, which doubles as the agent so a tool whose own hook is connected is skipped, and the pane's id, so a
/// click on the notice can go back to it.
enum TerminalBell {
    static var scriptURL: URL {
        NotifyServer.tokenURL.deletingLastPathComponent().appendingPathComponent("terminal-notify.sh")
    }

    /// Only letters, digits and `._-` of the names that go into headers; the rest goes in the body.
    static let script = """
        #!/bin/sh
        # Added by Nunsseop: shows bells from terminal panes in the notch.
        # tmux passes only its binary, socket name and the window's id; the names are read here, so nothing a
        # program can put in a window name reaches a command line.
        if [ "$1" = tmux-window ]; then
            tmux=$2 socket=$3 window=$4
            case "$window" in @[0-9]*) ;; *) exit 0 ;; esac
            case "${window#@}" in *[!0-9]*) exit 0 ;; esac
            t() { if [ -n "$socket" ]; then "$tmux" -L "$socket" "$@"; else "$tmux" "$@"; fi; }
            session=$(t display-message -p -t "$window" '#{session_name}')
            # The window is gone already (closed right after the bell): nothing to show.
            [ -n "$session" ] || exit 0
            name=$(t display-message -p -t "$window" '#{window_name}')
            commands=$(t list-panes -t "$window" -F '#{pane_current_command}')
            # tmux doesn't say which pane rang, so the running command counts as the agent only in a one-pane window.
            [ "$(printf '%s\n' "$commands" | wc -l | tr -d ' ')" = 1 ] || commands=
            set -- tmux "$session" "$name" "$commands" "$window"
        fi
        app=$(printf '%s' "$1" | tr -cd '[:alnum:]._-' | cut -c1-40)
        agent=$(printf '%s' "$4" | tr -cd '[:alnum:]._-' | cut -c1-40)
        target=$(printf '%s' "$5" | tr -cd '[:alnum:]%@._-' | cut -c1-40)
        bundle=$(printf '%s' "$__CFBundleIdentifier" | tr -cd '[:alnum:].-' | cut -c1-80)
        if [ -n "$2" ] && [ -n "$3" ]; then where="$2 · $3"; else where="$2$3"; fi
        printf '%s' "$where" | curl -s -m 2 -X POST http://127.0.0.1:\(NotifyServer.port)/notify \\
            \(NotifyServer.authHeaderOption) -H "X-Title: ${agent:-$app}" -H "X-Agent: $agent" \\
            -H "X-App: $bundle" -H "X-Target: ${target:+$app:$target}" --data-binary @- >/dev/null 2>&1
        exit 0

        """

    /// A script of an older version, which read the token and gave it to curl on its command line.
    static func isLegacy(script: String?) -> Bool { script?.contains("Bearer") == true }

    /// Replaces a script that is there, and adds none: with notifications off nothing asked for one.
    static func installIfPresent(at url: URL = scriptURL) {
        if FileManager.default.fileExists(atPath: url.path) { install(at: url) }
    }

    /// Writes the current script, so one from an older version doesn't linger.
    static func install(at url: URL = scriptURL, script: String = script) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
    }
}

// MARK: - WezTerm

/// WezTerm's config is Lua the user writes, so Nunsseop doesn't change it; it offers lines to paste instead.
/// They run the bell script without a shell, so pane titles can't turn into commands.
enum WezTerm {
    static let bundleID = "com.github.wez.wezterm"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            || ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var cli: URL? {
        let bundled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .appendingPathComponent("Contents/MacOS/wezterm")
        return ([bundled?.path] + ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"]).compactMap { $0 }
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Activates the pane and brings WezTerm forward.
    static func focus(pane: String, cli: URL? = WezTerm.cli) {
        guard !pane.isEmpty, pane.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // --no-auto-start: otherwise, with no GUI running, a mux server starts and holds the output open.
            if let cli { _ = TerminalFocus.run(cli, ["cli", "--no-auto-start", "activate-pane", "--pane-id", pane]) }
            DispatchQueue.main.async { TerminalFocus.activate(bundleID: bundleID) }
        }
    }

    static func snippet(script: URL = TerminalBell.scriptURL) -> String {
        """
        -- Nunsseop: show bells from WezTerm panes in the notch, at most one per pane every 2 seconds or so.
        local nunsseop_last_bell = {}
        wezterm.on('bell', function(window, pane)
          local id, now = pane:pane_id(), os.time()
          -- os.time() counts whole seconds, so < 3 waits at least 2 seconds.
          if nunsseop_last_bell[id] and now - nunsseop_last_bell[id] < 3 then return end
          nunsseop_last_bell[id] = now
          local process = (pane:get_foreground_process_name() or ''):match('[^/]*$')
          wezterm.background_child_process({ [==[\(script.path)]==], 'WezTerm', window:active_workspace(), pane:get_title(), process, tostring(pane:pane_id()) })
        end)
        """
    }
}

// MARK: - tmux

/// tmux has no notification feed, but it runs a hook whenever a window rings the bell, which is how agents such as
/// Claude Code (with its terminal bell setting) say they're done or waiting. Nunsseop adds that hook to the running
/// server only, at an index of its own, so neither tmux.conf nor the user's own alert-bell hooks change.
enum Tmux {
    static let hookIndex = 4775
    static var hook: String { "alert-bell[\(hookIndex)]" }

    static var binary: URL? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { binary != nil }

    /// The hook's tmux command. Only values Nunsseop knows (the script, tmux and the socket name, single-quoted) and
    /// the window id (`@` and digits) go in: names would be expanded by the shell even with `#{q:}`, which leaves
    /// braces, commas and `~` alone. nil when a path has characters tmux or sh would read into.
    static func hookCommand(script: URL, binary: URL, socketName: String? = nil) -> String? {
        let values = [script.path, binary.path, socketName ?? ""]
        guard values.allSatisfy({ !$0.contains(where: { "'\"\\$#`\n".contains($0) }) }) else { return nil }
        let quoted = values.map { "'\($0)'" }
        return "run-shell -b \"\(quoted[0]) tmux-window \(quoted[1]) \(quoted[2]) #{window_id}\""
    }

    /// A tmux id: `%` and digits for a pane, `@` and digits for a window.
    static func isID(_ value: String, prefix: Character) -> Bool {
        value.count > 1 && value.first == prefix && value.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Selects the pane or window, and brings forward the terminal app showing that session.
    static func focus(pane: String, binary: URL? = Tmux.binary, socketName: String? = nil) {
        guard let binary, isID(pane, prefix: "%") || isID(pane, prefix: "@") else { return }
        let socket = socketName.map { ["-L", $0] } ?? []
        DispatchQueue.global(qos: .userInitiated).async {
            let tmux = { (arguments: [String]) in TerminalFocus.run(binary, socket + arguments) }
            _ = tmux(["select-window", "-t", pane])
            if pane.hasPrefix("%") { _ = tmux(["select-pane", "-t", pane]) }
            // A client showing the pane's session, else any client, switched to it.
            let session = tmux(["display-message", "-p", "-t", pane, "#{session_name}"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Without the session (the pane is gone, say) there's no client to pick.
            guard !session.isEmpty else { return }
            var clients = (tmux(["list-clients", "-t", session, "-F", "#{client_pid} #{client_tty}"]) ?? "")
                .split(separator: "\n")
            if clients.isEmpty, let any = (tmux(["list-clients", "-F", "#{client_pid} #{client_tty}"]) ?? "").split(separator: "\n").first {
                let tty = any.split(separator: " ").dropFirst().joined(separator: " ")
                _ = tmux(["switch-client", "-c", tty, "-t", pane])
                clients = [any]
            }
            let pids = clients.compactMap { $0.split(separator: " ").first.flatMap { pid_t($0) } }
            DispatchQueue.main.async { pids.lazy.compactMap(TerminalFocus.hostingApp(of:)).first.map(TerminalFocus.activate) }
        }
    }

    /// Whether the server has this version's hook; an older one (different arguments) is replaced.
    static func isHooked(_ showHooks: String, command: String) -> Bool {
        showHooks.split(separator: "\n").contains { $0 == "\(hook) \(command)" }
    }

    /// What's in Nunsseop's slot, `alert-bell[4775]`, if anything.
    static func slot(in showHooks: String) -> String? {
        showHooks.split(separator: "\n").first { $0.hasPrefix(hook + " ") }.map(String.init)
    }

    /// Whether a hook in the slot is Nunsseop's, this version's or an older one: it runs Nunsseop's bell script.
    /// Anything else there belongs to the user and is neither replaced nor removed.
    static func isOurs(_ line: String, script: URL = TerminalBell.scriptURL) -> Bool {
        line.contains(script.path) || line.contains("/Nunsseop/terminal-notify.sh") || line.contains("/Nunsseop/tmux-notify.sh")
    }
}

@MainActor
final class TmuxWatcher {
    private let binary: URL?
    private let socketName: String?
    private let scriptURL: URL
    private let script: String
    private var timer: Timer?
    private var quitObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "nunsseop.tmux")

    /// `socketName` picks a server started with `tmux -L`; nil is the default one.
    init(binary: URL? = Tmux.binary, socketName: String? = nil, scriptURL: URL = TerminalBell.scriptURL,
         script: String = TerminalBell.script) {
        self.binary = binary
        self.socketName = socketName
        self.scriptURL = scriptURL
        self.script = script
    }

    func start() {
        guard timer == nil, binary != nil else { return }
        TerminalBell.install(at: scriptURL, script: script)
        // On quit the hook comes off before Nunsseop exits.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(waiting: true) }
        }
        check()
        // A tmux server started later, or again, gets the hook within this time.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 2
    }

    /// Takes the hook off the running server too.
    func stop(waiting: Bool = false) {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        let unhook = unhookIfOurs
        if waiting { queue.sync(execute: unhook) } else { queue.async(execute: unhook) }
    }

    /// Takes off a hook left by a Nunsseop that crashed while the feature is now off. Only Nunsseop's own.
    func clearLeftover() {
        guard timer == nil, binary != nil else { return }
        queue.async(execute: unhookIfOurs)
    }

    private var unhookIfOurs: @Sendable () -> Void {
        let run = runner, script = scriptURL
        return {
            guard let hooks = run(["show-hooks", "-g"]), let line = Tmux.slot(in: hooks), Tmux.isOurs(line, script: script) else { return }
            _ = run(["set-hook", "-gu", Tmux.hook])
        }
    }

    /// Runs tmux with the given arguments; nil when it fails, as when no server is running.
    private var runner: @Sendable ([String]) -> String? {
        let binary = binary, socket = socketName.map { ["-L", $0] } ?? []
        return { arguments in
            guard let binary else { return nil }
            let process = Process()
            process.executableURL = binary
            process.arguments = socket + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }
    }

    private func check() {
        guard let binary, let command = Tmux.hookCommand(script: scriptURL, binary: binary, socketName: socketName) else { return }
        let run = runner, script = scriptURL
        queue.async {
            guard let hooks = run(["show-hooks", "-g"]), !Tmux.isHooked(hooks, command: command) else { return }
            // The slot holds someone else's hook: left alone.
            if let line = Tmux.slot(in: hooks), !Tmux.isOurs(line, script: script) { return }
            _ = run(["set-hook", "-g", Tmux.hook, command])
        }
    }
}

// MARK: - Going to the terminal a notice came from

enum TerminalFocus {
    /// Brings an app that's already running to the front. Apps that aren't running aren't launched for a notice.
    static func activate(bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first.map(activate)
    }

    /// That exact process, which matters when an app runs more than once (`open -n`, `wezterm start`). Under
    /// macOS 14's cooperative activation Nunsseop yields to it and asks for it, rather than going through
    /// NSWorkspace, which picks an instance itself and sends a reopen event that opens a window in apps showing none.
    /// Only the active app can hand activation over, and a click on the notch panel doesn't make Nunsseop active,
    /// so it becomes active for a moment first.
    static func activate(_ app: NSRunningApplication) {
        if !NSApp.isActive { NSApp.activate() }
        NSApp.yieldActivation(to: app)
        if !app.activate(from: .current, options: []) { app.activate() }
    }

    /// The app a process runs in, found by walking up its parents: a shell in Terminal, tmux's client in Ghostty...
    static func hostingApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// What clicking a local tool's notice does: the pane it named (tmux, WezTerm), else the app it ran in.
    /// nil when it said neither, so the notice opens the notch as before.
    static func action(app: String?, target: String?) -> (() -> Void)? {
        if let target {
            let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                switch parts[0].lowercased() {
                case "tmux": return { Tmux.focus(pane: parts[1]) }
                case "wezterm": return { WezTerm.focus(pane: parts[1]) }
                default: break
                }
            }
        }
        guard let app, !NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty else { return nil }
        return { activate(bundleID: app) }
    }

    /// Runs a command and returns its output, or nil when it fails; for the terminals' own command-line tools.
    /// - environment: what the command gets in place of Nunsseop's own.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Sends each line to a Unix socket and waits for one reply line to each, in order.
    @discardableResult
    static func send(_ lines: [String], toSocket path: String, timeout: TimeInterval = 2) -> [String] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var time = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        // Writing after the other side closed (Muxy does after one reply) fails instead of killing Nunsseop with SIGPIPE.
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return [] }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return [] }
        var replies: [String] = []
        var pending = Data()
        for line in lines {
            let out = Array((line + "\n").utf8)
            guard out.withUnsafeBytes({ write(fd, $0.baseAddress, out.count) }) == out.count else { break }
            var reply: String?
            while reply == nil {
                if let newline = pending.firstIndex(of: 0x0A) {
                    reply = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    break
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { break }
                pending.append(contentsOf: chunk[0..<count])
            }
            guard let reply else { break }
            replies.append(reply)
        }
        return replies
    }
}
