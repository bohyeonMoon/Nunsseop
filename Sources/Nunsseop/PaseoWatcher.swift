import AppKit

/// Paseo's tool-call permissions as cards of the notch. A request of Paseo's becomes a card tagged "Paseo" with Deny, Allow and
/// "Answer in Paseo" (which only takes the card down and leaves the request pending for Paseo's own screens, and is not shown again).
/// Only a request for a tool call (`kind` `tool`) gets a card: a plan, a question or a mode change is answered in Paseo, and an
/// `ExitPlanMode` or `AskUserQuestion` call is left there as it is for the hooks' cards. Kept in memory only, like those.
@MainActor
final class PaseoApprovals {
    private struct Held {
        let agent: String
        let request: String
        let prompt: PermissionPrompt
    }

    /// Requests that were handed back to Paseo, remembered so a later listing does not bring them up again.
    static let rememberedDismissals = 256

    private let board: PermissionBoard
    private var held: [UUID: Held] = [:]
    private var cards: [String: UUID] = [:]
    private var dismissed: [String] = []
    /// Whether cards are wanted at all (the setting).
    var isEnabled: () -> Bool = { true }
    /// The folder an agent runs in, for the card's title.
    var folder: (String) -> String = { _ in "" }
    /// Sends an answer to the daemon; false when there is no connection to send it on.
    var send: (_ agent: String, _ request: String, _ allow: Bool) -> Bool = { _, _, _ in false }

    init(board: PermissionBoard) {
        self.board = board
    }

    /// The call as the hooks' parser reads a Claude Code request, so the card shows it the same way. A request with no `input` (an ACP
    /// provider's, Codex's file change) is shown by its title, description and detail instead.
    static func body(_ permission: PaseoPermission, folder: String) -> Data? {
        let input = permission.toolInput.isEmpty ? permission.shown : permission.toolInput
        return try? JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "tool_name": permission.name, "tool_input": input, "cwd": folder])
    }

    /// The card for a request, or nil when it can't be shown: not a tool call, nothing of it to read (the approval is left to Paseo
    /// rather than asked blind), or too large to show whole. A request without input is titled by the kind of tool it carries, in
    /// Nunsseop's own words: its title and description are the agent's, which could call a command "Read the README", so they stay
    /// in the body as named fields and never become the card's title.
    static func prompt(_ permission: PaseoPermission, folder: String) -> PermissionPrompt? {
        guard permission.kind == "tool", !permission.toolInput.isEmpty || !permission.shown.isEmpty,
              let body = body(permission, folder: folder), let prompt = PermissionPrompt.parse(body, tag: Paseo.name)?.prompt else { return nil }
        guard permission.toolInput.isEmpty, let title = kindTitle(permission.name) else { return prompt }
        return PermissionPrompt(id: prompt.id, title: title, symbol: prompt.symbol, detail: prompt.detail, flags: prompt.flags, secondary: prompt.secondary,
                                folder: prompt.folder, grant: prompt.grant, codex: prompt.isCodex, tag: prompt.tag)
    }

    /// Fixed titles for the tool kinds ACP providers and Codex send without input; nil leaves the tool's own name as the title.
    static func kindTitle(_ name: String) -> String? {
        switch name.lowercased() {
        case "execute": String(localized: "Run a command")
        case "edit": String(localized: "Edit a file")
        case "read": String(localized: "Read a file")
        case "fetch": String(localized: "Fetch a web page")
        case "search": String(localized: "Search the web")
        case "codexfilechange": String(localized: "Apply file changes")
        default: nil
        }
    }

    func added(agent: String, _ permission: PaseoPermission) {
        guard isEnabled(), cards[permission.id] == nil, !dismissed.contains(permission.id),
              let prompt = Self.prompt(permission, folder: folder(agent)) else { return }
        held[prompt.id] = Held(agent: agent, request: permission.id, prompt: prompt)
        cards[permission.id] = prompt.id
        board.add(prompt)
    }

    /// The request is answered (here or in Paseo) or gone: its card goes.
    func removed(request: String) {
        guard let id = cards.removeValue(forKey: request) else { return }
        held[id] = nil
        board.remove(id)
    }

    /// An answer from the board; false when the card is not one of Paseo's. Deny and Allow go to the daemon, and a card that could not
    /// be answered (the connection is gone) comes back.
    func answer(_ id: UUID, _ answer: PermissionAnswer) -> Bool {
        guard let entry = held[id] else { return false }
        switch answer {
        case .allow, .deny:
            if send(entry.agent, entry.request, answer == .allow) {
                held[id] = nil
                cards[entry.request] = nil
            } else {
                board.add(entry.prompt)
            }
        default:
            held[id] = nil
            cards[entry.request] = nil
            dismissed.append(entry.request)
            if dismissed.count > Self.rememberedDismissals { dismissed.removeFirst(dismissed.count - Self.rememberedDismissals) }
        }
        return true
    }

    /// Takes every card down, once cards are not wanted any more.
    func reset() {
        for id in held.keys { board.remove(id) }
        held = [:]
        cards = [:]
    }
}

/// What a finished or failed Paseo agent says in the notch.
struct PaseoNotice {
    let title: String
    let detail: String?
    let open: () -> Void
}

/// Paseo's agents for the board and its permissions for the notch, while the count or the Agents tab is showing (the board) and while
/// the setting wants them (cards and notices). The agents come from the daemon's record files, read off the main thread every
/// `interval`; the permissions and the "finished" and "failed" events from its WebSocket (see `PaseoClient`), which is opened only to a
/// daemon on this Mac that has no password and is never started by Nunsseop.
@MainActor
final class PaseoWatcher {
    static let interval: TimeInterval = 2
    /// Two events for one agent and reason within this long are one notice (a second connection of the same client may bring both).
    static let noticeGap: TimeInterval = 3
    static let cliGap: TimeInterval = 30

    let client: PaseoClient
    let approvals: PaseoApprovals
    var onNotice: ((PaseoNotice) -> Void)?

    private let board: AgentBoard
    private let isOn: () -> Bool
    private let wantsApprovals: () -> Bool
    private let wantsNotices: () -> Bool
    private let home: URL
    private let now: () -> Date
    private let isAlive: (Int32) -> Bool
    private let bootTime: () -> Date?
    private let cli: () -> URL?
    private let frontmostApp: () -> String?
    private let queue = DispatchQueue(label: "nunsseop.paseo", qos: .utility)

    private var scanner = PaseoScanner()
    private var tracker = PaseoTracker()
    private var records: [PaseoRecord] = []
    private var daemon: PaseoDaemon?
    private var url: URL?
    /// What the board was last given, so it is told only of a change: every update wakes the Agents tab.
    private var published: [String: AgentBoard.Agent] = [:]
    private var noticed: [String: Date] = [:]
    /// When each agent was last announced, whichever the reason.
    private var announced: [String: Date] = [:]
    private var cardsWanted = false
    private var looked: (at: Date, url: URL?)?
    private var timer: Timer?
    private var scanning = false
    /// Bumped by `reset`, so a scan that began before it is not applied.
    private var generation = 0

    /// - isOn: whether the closed notch shows the agents count or the Agents tab is on.
    /// - wantsApprovals: whether cards are wanted ("Answer permission prompts and questions in the notch").
    /// - wantsNotices: whether finished and failed agents are announced.
    /// - frontmostApp: the bundle id of the app in front; nothing is announced for an agent while its own app is.
    init(board: AgentBoard, permissions: PermissionBoard, isOn: @escaping () -> Bool, wantsApprovals: @escaping () -> Bool,
         wantsNotices: @escaping () -> Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser, now: @escaping () -> Date = { .now },
         isAlive: @escaping (Int32) -> Bool = Paseo.isAlive, bootTime: @escaping () -> Date? = Paseo.bootTime, cli: @escaping () -> URL? = { Paseo.cli() },
         frontmostApp: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         clientID: String = PaseoWatcher.clientID(), socket: @escaping (URL) -> PaseoSocket = { URLSessionPaseoSocket(url: $0) },
         timing: PaseoClient.Timing = PaseoClient.Timing(), refusal: PaseoRefusal = .shared) {
        self.board = board
        self.isOn = isOn
        self.wantsApprovals = wantsApprovals
        self.wantsNotices = wantsNotices
        self.home = home
        self.now = now
        self.isAlive = isAlive
        self.bootTime = bootTime
        self.cli = cli
        self.frontmostApp = frontmostApp
        approvals = PaseoApprovals(board: permissions)
        // The endpoint is read from what the last look at the pid file found.
        let location = Box()
        client = PaseoClient(endpoint: { location.url }, clientID: clientID, timing: timing, socket: socket)
        self.location = location
        approvals.isEnabled = wantsApprovals
        approvals.folder = { [home] in PaseoScanner.record(id: $0, home: home)?.cwd ?? "" }
        approvals.send = { [weak client] in client?.respond(agent: $0, request: $1, allow: $2) ?? false }
        client.onAdded = { [weak self] agent, permission in
            self?.approvals.added(agent: agent, permission)
            self?.publish()
        }
        client.onRemoved = { [weak self] _, request in
            self?.approvals.removed(request: request)
            self?.publish()
        }
        client.onAttention = { [weak self] agent, reason in self?.attention(agent: agent, reason: reason) }
        client.onState = { state in
            switch state {
            case .refused: refusal.value = true
            case .ready, .stopped: refusal.value = false
            default: break
            }
        }
    }

    private final class Box {
        var url: URL?
    }
    private let location: Box

    /// One id for this install, so the daemon takes a reconnect for the same client.
    nonisolated static func clientID(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: "paseoClientID"), saved.hasPrefix("nunsseop_") { return saved }
        let id = "nunsseop_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: "paseoClientID")
        return id
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        client.stop()
        approvals.reset()
        reset()
    }

    /// Forgets the agents, once the count isn't shown any more.
    func reset() {
        generation += 1
        tracker = PaseoTracker()
        records = []
        publish()
    }

    /// One look: at the daemon (and the connection to it), and, while the count or the tab is showing, at the agents.
    func poll() {
        let present = Paseo.isPresent(home: home, appInstalled: { false })
        daemon = present ? PaseoDaemon.read(home: home, bootTime: bootTime(), isAlive: isAlive) : nil
        syncClient()
        guard present, isOn() else {
            if !scanning { records = []; publish() }
            return
        }
        guard !scanning else { return }
        scanning = true
        let (generation, moment, home) = (generation, now(), home)
        var scanner = scanner
        queue.async { [weak self] in
            let found = scanner.scan(home: home, now: moment)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(found, scanner: scanner, generation: generation) }
            }
        }
    }

    private func finish(_ found: [PaseoRecord], scanner: PaseoScanner, generation: Int) {
        scanning = false
        self.scanner = scanner
        guard generation == self.generation else { return }
        records = found
        publish()
    }

    /// The connection runs while something wants it and there is a daemon on this Mac to reach that asks for no password.
    private func syncClient() {
        let wantsCards = wantsApprovals()
        if !wantsCards {
            approvals.reset()
        } else if !cardsWanted {
            // Cards were off while requests came in: the ones still waiting get theirs now.
            for (agent, permission) in client.pendingRequests { approvals.added(agent: agent, permission) }
        }
        cardsWanted = wantsCards
        url = daemon?.webSocketURL
        let reachable = url != nil && !Paseo.hasPassword(home: home)
        location.url = reachable ? url : nil
        if reachable && (wantsCards || wantsNotices()) { client.start() } else { client.stop() }
    }

    /// Where the command line is, looked for again every `cliGap`: finding it asks the system where the app is.
    private func commandLine() -> URL? {
        let moment = now()
        if let looked, moment.timeIntervalSince(looked.at) < Self.cliGap, moment >= looked.at { return looked.url }
        let url = cli()
        looked = (moment, url)
        return url
    }

    private func publish() {
        let moment = now()
        let agents = tracker.agents(records, daemon: daemon, pending: client.pendingAgents, cli: commandLine(), now: moment)
        guard agents != published else { return }
        let before = published
        published = agents
        board.replace(source: Paseo.source, with: agents, now: moment)
        finishes(from: before, to: agents)
    }

    /// The daemon tells of a finish once, while the flag it sets is clear: a turn that starts from the notch while an earlier finish is
    /// still unread ends with no event at all. So an agent seen at work that is now a finished hand is announced from here, unless an
    /// announcement came after its turn began (the event, which is quicker than the record).
    private func finishes(from before: [String: AgentBoard.Agent], to agents: [String: AgentBoard.Agent]) {
        for (id, agent) in agents where agent.finished {
            guard let was = before[id], was.state == .working || (was.state == .waiting && !was.finished) else { continue }
            if let last = announced[id], let began = was.since, last >= began { continue }
            if let reason = records.first(where: { $0.id == id })?.attention { attention(agent: id, reason: reason) }
        }
    }

    // MARK: Notices

    /// A finished or failed agent, announced unless its app is in front: that is where it is being looked at. A permission is the card's
    /// business.
    private func attention(agent: String, reason: String) {
        guard wantsNotices(), reason == "finished" || reason == "error", Paseo.isSafeID(agent), frontmostApp() != Paseo.bundleID else { return }
        let moment = now()
        noticed = noticed.filter { moment.timeIntervalSince($0.value) < Self.noticeGap }
        guard noticed["\(agent)|\(reason)"] == nil else { return }
        noticed["\(agent)|\(reason)"] = moment
        announced = announced.filter { moment.timeIntervalSince($0.value) < AgentBoard.recentWindow }
        announced[agent] = moment
        let record = PaseoScanner.record(id: agent, home: home)
        let name = record?.title ?? record.map { ($0.cwd as NSString).lastPathComponent }
        let state = reason == "error" ? String(localized: "Stopped with an error") : String(localized: "Finished")
        let server = daemon?.serverID
        onNotice?(PaseoNotice(title: String("\(Paseo.name) · \(name ?? String(agent.prefix(8)))".prefix(80)), detail: state) {
            DispatchQueue.global(qos: .userInitiated).async { _ = AgentSend.run([Paseo.openStep(server: server, agent: agent)]) }
        })
    }
}

extension PaseoScanner {
    /// One agent's record, by its id: the file is named for it, in the folder of its place.
    static func record(id: String, home: URL) -> PaseoRecord? {
        guard Paseo.isSafeID(id) else { return nil }
        let root = Paseo.folder(home: home).appendingPathComponent("agents", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for url in [root] + folders {
            let file = url.appendingPathComponent("\(id).json")
            if let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let record = PaseoRecord(json: object) { return record }
        }
        return nil
    }
}

/// Whether the daemon answered the hello with a refusal: a password it was given in its environment, which no file shows. Kept for
/// Settings, which isn't wired to the watcher; true from the refusal until the connection is ready again or switched off.
final class PaseoRefusal: @unchecked Sendable {
    static let shared = PaseoRefusal()
    private let lock = NSLock()
    private var refused = false

    var value: Bool {
        get { lock.withLock { refused } }
        set { lock.withLock { refused = newValue } }
    }
}

/// What Settings says of Paseo, from the same files the watcher reads, and the daemon's own refusal.
struct PaseoStatus: Equatable {
    var present = false
    var daemonRunning = false
    var cliFound = false
    /// The daemon has a password, or is only on a socket: the cards and notices need to reach it over TCP without one.
    var approvalsAvailable = true

    static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser, app: URL? = Paseo.appURL(), isAlive: (Int32) -> Bool = Paseo.isAlive,
                        bootTime: Date? = Paseo.bootTime(), refused: Bool = PaseoRefusal.shared.value) -> PaseoStatus {
        guard Paseo.isPresent(home: home, appInstalled: { app != nil }) else { return PaseoStatus() }
        let daemon = PaseoDaemon.read(home: home, bootTime: bootTime, isAlive: isAlive)
        return PaseoStatus(present: true, daemonRunning: daemon != nil, cliFound: Paseo.cli(home: home, app: app) != nil,
                           approvalsAvailable: (daemon.map { $0.starting || $0.webSocketURL != nil } ?? true) && !Paseo.hasPassword(home: home) && !refused)
    }
}
