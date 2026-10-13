import AppKit

/// Muxy 2: the app, its command-line tool and its profile folder. Muxy 1 (a `notifications.json` feed and a `muxy.sock` text socket) is
/// not supported: Muxy 2 has neither.
enum Muxy {
    static let bundleID = "com.muxy.app"

    /// Where Muxy 2 keeps its state (`desktop-state.json`, `extension-storage/`...).
    static var profile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Muxy 2", isDirectory: true)
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil || FileManager.default.fileExists(atPath: profile.path)
    }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    static var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var cli: URL? {
        let url = app?.appendingPathComponent("Contents/MacOS/muxy")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }
}

/// One agent in `muxy activity list --json`. Muxy 2 detects agents itself; ids are 64-bit numbers it prints as strings.
struct MuxyAgent: Equatable {
    let session: String
    let project: String
    /// As Muxy names it: "Claude", "Codex", "OpenCode", "Cursor"...
    let provider: String
    /// "unknown", "idle", "working" or "blocked".
    let state: String
}

/// One entry of Muxy's activity history: an agent needs you ("Attention") or finished ("Completed").
struct MuxyEvent: Equatable {
    enum Kind: Equatable {
        case attention, completed
        case other(String)
    }

    let id: String
    let session: String
    let project: String
    let provider: String
    let timestamp: TimeInterval
    let kind: Kind
    let read: Bool

    /// The tool whose own Nunsseop hook, when connected, already sends this event's notification.
    var integration: NotifyIntegration? { NotifyIntegration.forAgent(provider) }

    /// The agent as Nunsseop names it ("Claude Code" for Muxy's "Claude").
    static func displayName(_ provider: String) -> String { AgentKind(tool: provider)?.displayName ?? provider }

    /// Whether it is one of the two kinds Muxy sends, which have a notice.
    var announces: Bool {
        if case .other = kind { false } else { true }
    }

    /// "Claude Code in DEV needs input" or "... finished"; without a project name, "Claude Code needs input". nil for a kind it doesn't know.
    func notice(project name: String?) -> String? {
        let provider = Self.displayName(provider)
        switch (kind, name?.isEmpty == false ? name : nil) {
        case (.attention, let name?): return String(localized: "\(provider) in \(name) needs input")
        case (.attention, nil): return String(localized: "\(provider) needs input")
        case (.completed, let name?): return String(localized: "\(provider) in \(name) finished")
        case (.completed, nil): return String(localized: "\(provider) finished")
        case (.other, _): return nil
        }
    }
}

/// What `muxy activity list --json` prints: `{"revision":N,"agents":[...],"events":[...]}`.
struct MuxyActivity: Equatable {
    var revision: UInt64 = 0
    var agents: [MuxyAgent] = []
    var events: [MuxyEvent] = []

    /// nil when the text isn't that object, as when the tool printed an error.
    static func parse(_ data: Data) -> MuxyActivity? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["agents"] is [Any] || root["events"] is [Any] else { return nil }
        var activity = MuxyActivity(revision: (root["revision"] as? NSNumber)?.uint64Value ?? 0)
        for case let entry as [String: Any] in root["agents"] as? [Any] ?? [] {
            guard let session = id(entry["session"]) else { continue }
            activity.agents.append(MuxyAgent(session: session, project: id(entry["project"]) ?? "", provider: provider(entry["provider"]),
                                             state: entry["state"] as? String ?? "unknown"))
        }
        for case let entry as [String: Any] in root["events"] as? [Any] ?? [] {
            guard let eventID = id(entry["id"]), let session = id(entry["session"]) else { continue }
            let kind: MuxyEvent.Kind
            switch entry["kind"] as? String {
            case "Attention": kind = .attention
            case "Completed": kind = .completed
            case let other: kind = .other(other ?? "")
            }
            activity.events.append(MuxyEvent(id: eventID, session: session, project: id(entry["project"]) ?? "", provider: provider(entry["provider"]),
                                             timestamp: (entry["timestamp"] as? NSNumber)?.doubleValue ?? 0, kind: kind, read: entry["read"] as? Bool ?? false))
        }
        return activity
    }

    /// An id as a string: Muxy prints its 64-bit ids that way, but a number is read exactly as well.
    private static func id(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return String(number.uint64Value) }
        return nil
    }

    /// A provider Muxy has a name for is a string; one it only knows by number is no name.
    private static func provider(_ value: Any?) -> String { (value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Agent" }
}

/// `muxy project list --json`: the name and folder of each project, for the text of a notice and the folder of a row.
struct MuxyProjects: Equatable {
    var names: [String: String] = [:]
    var folders: [String: String] = [:]

    static func parse(_ data: Data) -> MuxyProjects? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var projects = MuxyProjects()
        for entry in list {
            guard let id = entry["id"] as? String else { continue }
            if let name = entry["name"] as? String { projects.names[id] = name }
            if let folder = entry["directory"] as? String { projects.folders[id] = folder }
        }
        return projects
    }
}

/// Which of Muxy's events are new: the list read first is only remembered, so history isn't replayed.
struct MuxyEventTracker {
    private var ids: Set<String>?
    private var revision: UInt64?

    /// Unread events that weren't in the list before. A lower revision than the last means Muxy's server restarted and numbers its
    /// events anew: what is listed then is only remembered.
    mutating func fresh(in activity: MuxyActivity) -> [MuxyEvent] {
        let current = Set(activity.events.map(\.id))
        let restarted = revision.map { activity.revision < $0 } ?? false
        defer { (ids, revision) = (current, activity.revision) }
        guard let ids, !restarted else { return [] }
        return activity.events.filter { !ids.contains($0.id) && !$0.read }
    }
}

/// The agents Muxy lists as working or blocked, as the board's agents, with the time each entered its state. An idle or unknown agent is
/// not listed. The hooks of a provider that has one are the better source of the same session: the board drops this one (see `AgentBoard`).
struct MuxyBoardTracker {
    private var entered: [String: (state: String, since: Date)] = [:]

    mutating func agents(for activity: MuxyActivity, projects: MuxyProjects, now: Date) -> [String: AgentBoard.Agent] {
        var agents: [String: AgentBoard.Agent] = [:]
        var next: [String: (state: String, since: Date)] = [:]
        for agent in activity.agents where agent.state == "working" || agent.state == "blocked" {
            let since = entered[agent.session].flatMap { $0.state == agent.state ? $0.since : nil } ?? now
            next[agent.session] = (agent.state, since)
            agents[agent.session] = AgentBoard.Agent(
                state: agent.state == "working" ? .working : .waiting, since: since,
                tool: AgentKind(tool: agent.provider)?.rawValue ?? agent.provider, app: Muxy.bundleID,
                cwd: projects.folders[agent.project], input: AgentInput.muxySession(agent.session).map { .muxy($0) })
        }
        entered = next
        return agents
    }
}

/// How the watcher reaches Muxy; tests give it a made-up one.
struct MuxyBackend: Sendable {
    var isRunning: @Sendable () -> Bool
    /// Whether the server answers. `muxy server status` doesn't start it; `activity list` does.
    var serverUp: @Sendable () -> Bool
    var activity: @Sendable () -> Data?
    var projects: @Sendable () -> Data?

    static let live = MuxyBackend(
        isRunning: { Muxy.isRunning },
        serverUp: { run(["server", "status", "--json"]).map { String(decoding: $0, as: UTF8.self).contains("\"instance\"") } ?? false },
        activity: { run(["activity", "list", "--json"]) },
        projects: { run(["project", "list", "--json"]) })

    /// Without Nunsseop's terminal variables: a tool started from a Muxy terminal would take them for its own session.
    private static func run(_ arguments: [String]) -> Data? {
        guard let cli = Muxy.cli else { return nil }
        return TerminalFocus.run(cli, arguments, environment: AgentSend.cleanEnvironment).map { Data($0.utf8) }
    }
}

/// Watches Muxy 2's agent activity: new events become notices, and agents working or blocked go to the board (source "muxy"). It looks
/// every `interval` seconds, off the main thread, one look at a time, and only while Muxy runs, its server answers and a notice or the
/// board wants the result. It never acknowledges an event: Muxy's own unread marks stay as they are.
@MainActor
final class MuxyActivityWatcher {
    nonisolated static let interval: TimeInterval = 2
    nonisolated static let source = "muxy"
    /// How long the project names are kept before they are read again (a project that was renamed or added).
    nonisolated static let projectsLifetime: TimeInterval = 60
    /// How soon a project the names don't have is looked for again: one that was deleted stays in Muxy's event history.
    nonisolated static let unknownProjectRetry: TimeInterval = 5

    /// The newest new event, with its project's name when known.
    /// `folder` is the project's, for going to a session the desktop state has no pane for.
    var onNotice: ((MuxyEvent, _ project: String?, _ folder: String?) -> Void)?
    /// Whether notices are wanted (the setting is on and the notch is showing).
    var noticesEnabled = false
    /// Whether the agents count or the Agents tab is showing.
    var wantsBoard: () -> Bool = { false }

    private let board: AgentBoard
    private let backend: MuxyBackend
    private let now: () -> Date
    private let frontmost: () -> String?
    private let hooked: (MuxyEvent) -> Bool
    private var events = MuxyEventTracker()
    private var boardTracker = MuxyBoardTracker()
    private var projects = MuxyProjects()
    private var projectsRead: Date?
    private var published: [String: AgentBoard.Agent] = [:]
    private var timer: Timer?
    /// Whether a look is under way.
    private(set) var looking = false
    /// Bumped when the look is given up, so one that began before is not applied.
    private var generation = 0
    private let queue = DispatchQueue(label: "nunsseop.muxy", qos: .utility)

    init(board: AgentBoard, backend: MuxyBackend = .live, now: @escaping () -> Date = { .now },
         frontmost: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         hooked: @escaping (MuxyEvent) -> Bool = { $0.integration?.isInstalled == true }) {
        self.board = board
        self.backend = backend
        self.now = now
        self.frontmost = frontmost
        self.hooked = hooked
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
        reset()
    }

    /// Forgets everything, once nothing wants it or Muxy is gone: what is listed when it is looked at again is only remembered.
    func reset() {
        generation += 1
        events = MuxyEventTracker()
        boardTracker = MuxyBoardTracker()
        publish([:])
    }

    private func publish(_ agents: [String: AgentBoard.Agent], at moment: Date = .now) {
        guard agents != published else { return }
        published = agents
        board.replace(source: Self.source, with: agents, now: moment)
    }

    /// One look, when Muxy runs and a notice or the board wants it.
    func poll() {
        let backend = backend
        guard noticesEnabled || wantsBoard(), backend.isRunning() else {
            if !looking { reset() }
            return
        }
        guard !looking else { return }
        looking = true
        let moment = now()
        let generation = generation
        let age = projectsRead.map { moment.timeIntervalSince($0) }
        let known = age.flatMap { $0 < Self.projectsLifetime ? projects : nil }
        queue.async { [weak self] in
            var activity: MuxyActivity?
            var list = known
            var fetched = false
            if backend.serverUp(), let data = backend.activity() {
                activity = MuxyActivity.parse(data)
                // A project the names don't have is read for again (once in a while), in the same look.
                let wanted = Set((activity?.agents.map(\.project) ?? []) + (activity?.events.map(\.project) ?? [])).subtracting([""])
                let missing = !wanted.isSubset(of: (list?.names ?? [:]).keys)
                if list == nil || (missing && (age ?? 0) >= Self.unknownProjectRetry) {
                    list = backend.projects().flatMap(MuxyProjects.parse) ?? list
                    fetched = true
                }
            }
            let (result, projects) = (activity, list)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(result, projects: projects, fetched: fetched, generation: generation, at: moment) }
            }
        }
    }

    private func finish(_ activity: MuxyActivity?, projects list: MuxyProjects?, fetched: Bool, generation: Int, at moment: Date) {
        looking = false
        guard generation == self.generation else { return }
        guard let activity else { return reset() }
        if let list, fetched { (projects, projectsRead) = (list, moment) }
        let fresh = events.fresh(in: activity)
        let board = wantsBoard() ? boardTracker.agents(for: activity, projects: projects, now: moment) : [:]
        publish(board, at: moment)
        // Muxy shows its own toast while it is in front. Several at once show as the newest. A tool whose own hook is connected sends its own.
        guard noticesEnabled, frontmost() != Muxy.bundleID,
              let newest = fresh.filter({ $0.announces && !hooked($0) }).max(by: { ($0.timestamp, Self.number($0.id)) < ($1.timestamp, Self.number($1.id)) })
        else { return }
        onNotice?(newest, projects.names[newest.project], projects.folders[newest.project])
    }

    private static func number(_ id: String) -> UInt64 { UInt64(id) ?? 0 }
}
