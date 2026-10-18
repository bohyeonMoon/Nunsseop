import AppKit

/// One tool's sessions (Claude Code's, Codex's, pi's, omp's, omo's or OpenCode's) for the agents count and the Agents tab, told by the
/// hooks, extension or plugin Nunsseop installs, so one running in Muxy or a plain terminal shows up as well as one in herdr. Every session is an entry that stays listed for
/// `AgentBoard.recentWindow` after its latest event, because a hook can't say when a turn is cut short with Esc or the
/// tool is killed: neither sends an event (Codex does send Interrupt). One that reports its process (`pid`) is dropped as
/// soon as that process is gone. One instance per tool, each a source of its own, so two tools' session ids can't meet.
///
/// A session counts as working, or as asking for input, for `activeWindow` after its event and is idle from then on, as
/// a finished hand nobody looked at is after `Herdr.doneWindow`. Claude Code's `PostToolUse` comes once a tool has run, so after a
/// permission or a question is answered (in the notch or the terminal) the first tool to finish puts the session back to work; while
/// it works, each one also keeps it from turning idle.
///
/// Claude Code's `Stop` comes while a background subagent still runs, and the subagent's `SubagentStop` later. The running
/// subagents are kept per session (`subagents`): a `Stop` with any left keeps the session working, and the last `SubagentStop`
/// ends the turn as the `Stop` would have. A subagent that never says it stopped is forgotten `activeWindow` after its start,
/// or `backgroundWindow` after the `Stop` or start that came once the turn was over.
/// Background shell commands send no event, but Claude Code's `Stop` lists everything still running (`background_tasks`, sent
/// as `X-Background-Tasks`): a count above 0 keeps the session working for `backgroundWindow` after that `Stop`, and the `Stop`
/// of the turn that follows the hand-back says the new count, 0 when all are done. That count includes the subagents, so it is
/// the one shown when present. Only a turn that is over gets the longer window: one that is still running may have been cut
/// short with Esc, which sends no event, so it keeps `activeWindow`.
@MainActor
final class AgentHooks {
    /// How long a session keeps counting as working, or as asking for input, after its last event.
    static let activeWindow: TimeInterval = 20 * 60
    /// How long a session whose turn is over keeps counting as working while background tasks or subagents still run, with no
    /// event to say when they end. Less than `AgentBoard.recentWindow`, so the session is still listed while it counts.
    static let backgroundWindow: TimeInterval = 2 * 60 * 60
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
        /// Whether its latest event says it runs in tmux, zellij or screen.
        var inMultiplexer = false
        /// The turn has ended and only background tasks keep it working.
        var turnOver = false
        /// What the `Stop` that ended the turn said still runs (0 when it said nothing), subagents and shell commands together.
        var stopTasks = 0
        /// When it entered this state; another event in the same state keeps it.
        var since: Date
        /// When it stops counting and is idle.
        var idleFrom: Date?
        /// The time of its latest event; it goes `AgentBoard.recentWindow` after, and never while it still counts as working.
        var lastUsed: Date
        var expiresAt: Date { max(lastUsed.addingTimeInterval(AgentBoard.recentWindow), idleFrom ?? .distantPast) }

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
    /// Each session's running subagents by id, and when each is forgotten if it never says it stopped.
    private var subagents: [String: [String: Date]] = [:]
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
        forgetSubagents(now: now)
        let id = event.session
        // One process has one session at a time: /resume or /clear inside it starts another id. Not OpenCode, whose plugin lives in
        // the server, where one process hosts several sessions at once, nor the others that do (see `AgentKind.sharesProcess`).
        if let pid = event.pid, event.action != .remove, !kind.sharesProcess {
            entries = entries.filter { $0.key == id || $0.value.pid != pid }
        }
        switch event.action {
        case .working:
            limitSubagents(id, to: now.addingTimeInterval(Self.activeWindow))
            set(id, .working, idleFrom: later(now.addingTimeInterval(Self.activeWindow), id), event: event, now: now)
        case .needsInput:
            set(id, .waiting, idleFrom: now.addingTimeInterval(Self.activeWindow), event: event, now: now)
        case .toolRan:
            // Only within a turn: a subagent's tool after the turn's Stop must not take away the finished hand, nor revive one that is idle.
            guard let entry = entries[id], !entry.turnOver, entry.settled(at: now).state != .idle,
                  entry.state == .working || !entry.finished else { break }
            set(id, .working, idleFrom: later(now.addingTimeInterval(Self.activeWindow), id), event: event, now: now)
        case .finished:
            finish(id, event: event, now: now)
        case .idle:
            // Claude Code only says idle with no dialog open, and Codex when a turn is interrupted, so a question or a
            // working turn is over; a finished hand stays, and so does a session whose turn is over and only subagents keep it
            // working. Mid-turn it means the turn was interrupted, so a subagent that never said it stopped is forgotten.
            if entries[id]?.finished != true, entries[id]?.turnOver != true {
                subagents[id] = nil
                set(id, .idle, event: event, now: now)
            }
        case .opened:
            // Also sent on resume, clear and compact, which can come mid-turn: what it was doing stays.
            if var entry = entries[id] {
                entry.app = event.app ?? entry.app
                entry.pid = event.pid ?? entry.pid
                entry.input = event.input
                entry.inMultiplexer = event.inMultiplexer
                entry.lastUsed = now
                entries[id] = entry
            } else {
                set(id, .idle, event: event, now: now)
            }
        case .remove:
            entries[id] = nil
        case .subagentStarted(let subagent):
            // Only a session already listed: the event carries nothing of the terminal it runs in.
            guard var entry = entries[id] else { break }
            subagents[id, default: [:]][subagent] = now.addingTimeInterval(entry.turnOver ? Self.backgroundWindow : Self.activeWindow)
            if entry.state == .working { entry.idleFrom = later(entry.idleFrom, id) }
            entry.lastUsed = now
            entries[id] = entry
        case .subagentStopped(let subagent):
            guard var entry = entries[id] else { break }
            subagents[id]?[subagent] = nil
            if subagents[id]?.isEmpty == true { subagents[id] = nil }
            entry.lastUsed = now
            entries[id] = entry
            // The last one ends a turn that only they kept going, as its Stop would have.
            if entry.turnOver, entry.stopTasks == 0, subagents[id] == nil {
                finish(id, event: AgentEvent(session: id, action: .finished, app: entry.app, agent: event.agent, pid: entry.pid,
                                             input: entry.input, inMultiplexer: entry.inMultiplexer), now: now)
            }
        }
        prune(now: now)
        publish(now: now)
    }

    /// The end of a turn: with background tasks still running the session keeps working, otherwise it is a finished hand (idle
    /// when the app it runs in is in front, because it is being looked at). The `Stop`'s own count of them, when it has one, is
    /// the whole truth: 0 means no subagent is left either; without one the subagents seen are counted.
    private func finish(_ id: String, event: AgentEvent, now: Date) {
        if event.backgroundTasks == 0 { subagents[id] = nil }
        if let tasks = event.backgroundTasks, tasks > 0 {
            set(id, .working, idleFrom: later(now.addingTimeInterval(Self.backgroundWindow), id), turnOver: true, stopTasks: tasks,
                event: event, now: now)
        } else if subagents[id] != nil {
            subagents[id] = subagents[id]?.mapValues { max($0, now.addingTimeInterval(Self.backgroundWindow)) }
            set(id, .working, idleFrom: later(nil, id), turnOver: true, event: event, now: now)
        } else if event.app != nil, event.app == frontmostApp() {
            // Finished in the app that's in front: it's being looked at.
            set(id, .idle, event: event, now: now)
        } else {
            set(id, .waiting, finished: true, idleFrom: now.addingTimeInterval(Herdr.doneWindow), event: event, now: now)
        }
    }

    /// `date` or, if later, when the session's last running subagent is forgotten.
    private func later(_ date: Date?, _ id: String) -> Date? {
        [date, subagents[id]?.values.max()].compactMap { $0 }.max()
    }

    /// Brings the forgetting of a session's subagents forward to `date` at the latest: a turn that is running again has no
    /// event to say it was cut short, so the longer wait that followed the last `Stop` doesn't carry over.
    private func limitSubagents(_ id: String, to date: Date) {
        subagents[id] = subagents[id]?.mapValues { min($0, date) }
    }

    /// Forgets the subagents that never said they stopped, and those of a session no longer listed.
    private func forgetSubagents(now: Date) {
        subagents = subagents.compactMapValues { ids in
            let live = ids.filter { $0.value > now }
            return live.isEmpty ? nil : live
        }.filter { entries[$0.key] != nil }
    }

    /// Forgets everything, once the count isn't shown any more.
    func reset() {
        subagents = [:]
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
            entries[id] = Entry(state: .idle, app: app, pid: entry.pid, input: entry.input, inMultiplexer: entry.inMultiplexer, since: now,
                                 lastUsed: entry.lastUsed)
        }
        publish(now: now)
    }

    private func set(_ id: String, _ state: AgentBoard.State, finished: Bool = false, idleFrom: Date? = nil, turnOver: Bool = false,
                     stopTasks: Int = 0, event: AgentEvent, now: Date) {
        let old = entries[id]
        // Compared as the board shows it: a hand that has turned idle since isn't in its old state any more.
        let shown = old?.settled(at: now)
        let same = shown.map { $0.state == state && $0.finished == finished } ?? false
        entries[id] = Entry(state: state, finished: finished, app: event.app, pid: event.pid ?? old?.pid,
                            input: event.input, inMultiplexer: event.inMultiplexer, turnOver: turnOver,
                            stopTasks: stopTasks, since: same ? shown!.since : now, idleFrom: idleFrom, lastUsed: now)
    }

    /// Drops the sessions that have expired or whose process is gone.
    private func prune(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now && ($0.value.pid.map(isAlive) ?? true) }
        forgetSubagents(now: now)
    }

    private func publish(now: Date) {
        board.replace(source: source, with: entries.reduce(into: [String: AgentBoard.Agent]()) { agents, entry in
            let (id, value) = entry
            agents[id] = AgentBoard.Agent(state: value.state, expiresAt: value.expiresAt, since: value.since,
                                          finished: value.finished, tool: kind.rawValue, app: value.app, session: id,
                                          idleFrom: value.idleFrom, input: value.input, pid: value.pid,
                                          inMultiplexer: value.inMultiplexer,
                                          background: !value.turnOver ? 0 : value.stopTasks > 0 ? value.stopTasks : subagents[id]?.count ?? 0)
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
