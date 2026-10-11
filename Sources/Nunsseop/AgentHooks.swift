import AppKit

/// Claude Code or Codex sessions for the agents count, told by the hooks Nunsseop installs, so one running in Muxy
/// or a plain terminal counts as well as one in herdr. Every session is an entry that expires, because a hook can't
/// say when a turn is cut short with Esc or the tool is killed: neither sends an event (Codex does send Interrupt).
/// One instance per tool, each a source of its own, so two tools' session ids can't meet.
///
/// Known limit: approving a permission sends no event either (PostToolUse isn't installed, to spare a process per
/// tool call), so an approved turn that then works silently keeps its hand until the next event, and drops out of
/// the count after `activeWindow` while it still runs, until its Stop.
@MainActor
final class AgentHooks {
    /// How long a session keeps counting as working, or as asking for input, after its last event.
    static let activeWindow: TimeInterval = 20 * 60
    let source: String

    private struct Entry {
        var state: AgentBoard.State
        /// Done and not yet looked at, as opposed to asking for input.
        var finished = false
        var app: String?
        /// When it entered this state; another event in the same state keeps it.
        var since: Date
        var expiresAt: Date
    }

    private let kind: AgentKind
    private let board: AgentBoard
    private let isOn: () -> Bool
    private let watchesHerdr: () -> Bool
    private let frontmostApp: () -> String?
    private var entries: [String: Entry] = [:]
    private var activation: NSObjectProtocol?

    /// - isOn: whether the closed notch shows the agents count or the Agents tab is on; nothing is kept while it isn't.
    /// - watchesHerdr: whether herdr's own count is running, which already includes a session in a herdr pane.
    init(board: AgentBoard, agent: AgentKind = .claude, isOn: @escaping () -> Bool, watchesHerdr: @escaping () -> Bool,
         frontmostApp: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.board = board
        self.kind = agent
        self.source = "hooks:\(agent.rawValue)"
        self.isOn = isOn
        self.watchesHerdr = watchesHerdr
        self.frontmostApp = frontmostApp
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
    }

    func apply(_ event: AgentEvent, now: Date = .now) {
        guard isOn(), !(event.inHerdr && watchesHerdr()) else { return }
        entries = entries.filter { $0.value.expiresAt > now }
        let id = event.session
        switch event.action {
        case .working:
            set(id, .working, app: event.app, until: now.addingTimeInterval(Self.activeWindow), now: now)
        case .needsInput:
            set(id, .waiting, app: event.app, until: now.addingTimeInterval(Self.activeWindow), now: now)
        case .finished:
            // Finished in the app that's in front: it's being looked at.
            if event.app != nil, event.app == frontmostApp() {
                entries[id] = nil
            } else {
                set(id, .waiting, finished: true, app: event.app, until: now.addingTimeInterval(Herdr.doneWindow), now: now)
            }
        case .idle:
            // Claude Code only says idle with no dialog open, and Codex when a turn is interrupted, so a question or a
            // working turn is over; a finished hand stays.
            if let entry = entries[id], !entry.finished { entries[id] = nil }
        case .remove:
            entries[id] = nil
        }
        publish(now: now)
    }

    /// Forgets everything, once the count isn't shown any more.
    func reset() {
        guard !entries.isEmpty else { return }
        entries = [:]
        board.clear(source: source)
    }

    func activated(_ app: String?) {
        guard let app, entries.values.contains(where: { $0.finished && $0.app == app }) else { return }
        entries = entries.filter { !($0.value.finished && $0.value.app == app) }
        publish(now: .now)
    }

    private func set(_ id: String, _ state: AgentBoard.State, finished: Bool = false, app: String?, until: Date, now: Date) {
        let same = entries[id].map { $0.state == state && $0.finished == finished } ?? false
        entries[id] = Entry(state: state, finished: finished, app: app, since: same ? entries[id]!.since : now, expiresAt: until)
    }

    private func publish(now: Date) {
        board.replace(source: source, with: entries.reduce(into: [String: AgentBoard.Agent]()) { agents, entry in
            let (id, value) = entry
            agents[id] = AgentBoard.Agent(state: value.state, expiresAt: value.expiresAt, since: value.since,
                                          finished: value.finished, tool: kind.rawValue, app: value.app, session: id)
        }, now: now)
    }
}

/// The hooks of both tools: an event goes to the tool it names, and hiding the count clears both.
@MainActor
struct ToolHooks {
    let claude: AgentHooks
    let codex: AgentHooks

    func apply(_ event: AgentEvent, now: Date = .now) {
        (event.agent == .codex ? codex : claude).apply(event, now: now)
    }

    func reset() {
        claude.reset()
        codex.reset()
    }
}
