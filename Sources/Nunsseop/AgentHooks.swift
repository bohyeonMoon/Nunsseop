import AppKit

/// One tool's sessions (Claude Code's, Codex's, pi's, omp's, omo's or OpenCode's) for the agents count and the Agents tab, told by the
/// hooks, extension or plugin Nunsseop installs, so one running in Muxy or a plain terminal shows up as well as one in herdr. Every session is an entry that stays listed for
/// `AgentBoard.recentWindow` after its latest event, because a hook can't say when a turn is cut short with Esc or the
/// tool is killed: neither sends an event (Codex does send Interrupt). One that reports its process (`pid`) is dropped as
/// soon as that process is gone. One instance per tool, each a source of its own, so two tools' session ids can't meet.
///
/// A session counts as working, or as asking for input, for `activeWindow` after its event and is idle from then on, as
/// a finished hand nobody looked at is after `Herdr.doneWindow`. Known limit: approving a permission sends no event
/// either (PostToolUse isn't installed, to spare a process per tool call), so an approved turn that then works silently
/// keeps its hand until the next event, and turns idle after `activeWindow` while it still runs, until its Stop.
@MainActor
final class AgentHooks {
    /// How long a session keeps counting as working, or as asking for input, after its last event.
    static let activeWindow: TimeInterval = 20 * 60
    /// How often the processes of the listed sessions are looked at.
    static let livenessInterval: TimeInterval = 60
    let source: String

    private struct Entry {
        var state: AgentBoard.State
        /// Done and not yet looked at, as opposed to asking for input.
        var finished = false
        var app: String?
        /// The tool's process, when the hook says it.
        var pid: Int32?
        /// Where the terminal it runs in takes input, when its latest event says: a session resumed in another terminal has no claim
        /// on the old one.
        var input: AgentInput?
        /// When it entered this state; another event in the same state keeps it.
        var since: Date
        /// When it stops counting and is idle.
        var idleFrom: Date?
        /// The time of its latest event; it goes `AgentBoard.recentWindow` after.
        var lastUsed: Date
        var expiresAt: Date { lastUsed.addingTimeInterval(AgentBoard.recentWindow) }

        /// What the board shows at `now`: idle from `idleFrom` on, since then.
        func settled(at now: Date) -> (state: AgentBoard.State, finished: Bool, since: Date) {
            guard state != .idle, let idleFrom, idleFrom <= now else { return (state, finished, since) }
            return (.idle, false, idleFrom)
        }
    }

    private let kind: AgentKind
    private let board: AgentBoard
    private let isOn: () -> Bool
    private let watchesHerdr: () -> Bool
    private let frontmostApp: () -> String?
    private let isAlive: (Int32) -> Bool
    private var entries: [String: Entry] = [:]
    private var activation: NSObjectProtocol?
    private(set) var liveness: Timer?

    /// - isOn: whether the closed notch shows the agents count or the Agents tab is on; nothing is kept while it isn't.
    /// - watchesHerdr: whether herdr's own count is running, which already includes a session in a herdr pane.
    /// - isAlive: whether a process still runs; one owned by another user does.
    init(board: AgentBoard, agent: AgentKind = .claude, isOn: @escaping () -> Bool, watchesHerdr: @escaping () -> Bool,
         frontmostApp: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         isAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.board = board
        self.kind = agent
        self.source = "hooks:\(agent.rawValue)"
        self.isOn = isOn
        self.watchesHerdr = watchesHerdr
        self.frontmostApp = frontmostApp
        self.isAlive = isAlive
        // Coming to an app looks at what finished in it. Muxy's tabs and the like aren't told apart.
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.activated(app) }
        }
    }

    deinit {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        liveness?.invalidate()
    }

    func apply(_ event: AgentEvent, now: Date = .now) {
        guard isOn(), !(event.inHerdr && watchesHerdr()) else { return }
        entries = entries.filter { $0.value.expiresAt > now }
        let id = event.session
        // One process has one session at a time: /resume or /clear inside it starts another id. Not OpenCode, whose plugin lives in
        // the server, where one process hosts several sessions at once.
        if let pid = event.pid, event.action != .remove, kind != .opencode {
            entries = entries.filter { $0.key == id || $0.value.pid != pid }
        }
        switch event.action {
        case .working:
            set(id, .working, idleFrom: now.addingTimeInterval(Self.activeWindow), event: event, now: now)
        case .needsInput:
            set(id, .waiting, idleFrom: now.addingTimeInterval(Self.activeWindow), event: event, now: now)
        case .finished:
            // Finished in the app that's in front: it's being looked at.
            if event.app != nil, event.app == frontmostApp() {
                set(id, .idle, event: event, now: now)
            } else {
                set(id, .waiting, finished: true, idleFrom: now.addingTimeInterval(Herdr.doneWindow), event: event, now: now)
            }
        case .idle:
            // Claude Code only says idle with no dialog open, and Codex when a turn is interrupted, so a question or a
            // working turn is over; a finished hand stays.
            if entries[id]?.finished != true { set(id, .idle, event: event, now: now) }
        case .opened:
            // Also sent on resume, clear and compact, which can come mid-turn: what it was doing stays.
            if var entry = entries[id] {
                entry.app = event.app ?? entry.app
                entry.pid = event.pid ?? entry.pid
                entry.input = event.input
                entry.lastUsed = now
                entries[id] = entry
            } else {
                set(id, .idle, event: event, now: now)
            }
        case .remove:
            entries[id] = nil
        }
        prune(now: now)
        publish(now: now)
    }

    /// Forgets everything, once the count isn't shown any more.
    func reset() {
        liveness?.invalidate()
        liveness = nil
        guard !entries.isEmpty else { return }
        entries = [:]
        board.clear(source: source)
    }

    /// Coming to the app looks at what finished in it: it is idle now.
    func activated(_ app: String?) {
        let now = Date.now
        // One whose hand has turned idle already stays as the board shows it.
        let unseen = entries.filter { $0.value.app == app && $0.value.settled(at: now).finished }
        guard app != nil, !unseen.isEmpty else { return }
        for (id, entry) in unseen {
            entries[id] = Entry(state: .idle, app: app, pid: entry.pid, input: entry.input, since: now, lastUsed: entry.lastUsed)
        }
        publish(now: now)
    }

    private func set(_ id: String, _ state: AgentBoard.State, finished: Bool = false, idleFrom: Date? = nil, event: AgentEvent, now: Date) {
        let old = entries[id]
        // Compared as the board shows it: a hand that has turned idle since isn't in its old state any more.
        let shown = old?.settled(at: now)
        let same = shown.map { $0.state == state && $0.finished == finished } ?? false
        entries[id] = Entry(state: state, finished: finished, app: event.app, pid: event.pid ?? old?.pid,
                            input: event.input, since: same ? shown!.since : now, idleFrom: idleFrom, lastUsed: now)
    }

    /// Drops the sessions that have expired or whose process is gone.
    private func prune(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now && ($0.value.pid.map(isAlive) ?? true) }
    }

    private func publish(now: Date) {
        board.replace(source: source, with: entries.reduce(into: [String: AgentBoard.Agent]()) { agents, entry in
            let (id, value) = entry
            agents[id] = AgentBoard.Agent(state: value.state, expiresAt: value.expiresAt, since: value.since,
                                          finished: value.finished, tool: kind.rawValue, app: value.app, session: id,
                                          idleFrom: value.idleFrom, input: value.input, pid: value.pid)
        }, now: now)
        // A session's process can end without a word, so the ones that report theirs are looked at now and then.
        if entries.values.contains(where: { $0.pid != nil }) {
            guard liveness == nil else { return }
            let timer = Timer(timeInterval: Self.livenessInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pruneDead() }
            }
            timer.tolerance = 20
            RunLoop.main.add(timer, forMode: .common)
            liveness = timer
        } else {
            liveness?.invalidate()
            liveness = nil
        }
    }

    func pruneDead(now: Date = .now) {
        let before = entries.count
        prune(now: now)
        if entries.count != before { publish(now: now) }
    }
}

/// The hooks of every tool that reports through `/agent`: an event goes to the tool it names, and hiding the count clears all.
@MainActor
struct ToolHooks {
    private let byKind: [AgentKind: AgentHooks]

    /// - others: the hooks of the tools besides Claude Code and Codex.
    init(claude: AgentHooks, codex: AgentHooks, others: [AgentKind: AgentHooks] = [:]) {
        byKind = others.merging([.claude: claude, .codex: codex]) { $1 }
    }

    /// One `AgentHooks` for each tool that sends events.
    init(board: AgentBoard, isOn: @escaping () -> Bool, watchesHerdr: @escaping () -> Bool) {
        byKind = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, AgentHooks(board: board, agent: $0, isOn: isOn, watchesHerdr: watchesHerdr))
        })
    }

    func apply(_ event: AgentEvent, now: Date = .now) {
        byKind[event.agent]?.apply(event, now: now)
    }

    /// What the notch does with an event the server received: a kitty session's socket is kept (it is how a conversation is later
    /// resumed in kitty), then the event goes to the board.
    func receive(_ event: AgentEvent, defaults: UserDefaults = .standard) {
        Kitty.remember(event.input, in: defaults)
        apply(event)
    }

    func reset() {
        byKind.values.forEach { $0.reset() }
    }
}
