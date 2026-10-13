import Darwin
import Foundation

/// gajae-code (`gjc`) has no extension API, but each session keeps `<cwd>/.gjc/_session-<id>/runtime/runtime-state.json`: `state`
/// (`running`, `needs_user_input`, `ready_for_input`, `completed`, `errored`), `ready_for_input`, `live`, `cwd`, `session_id` and
/// `updated_at`. The file is rewritten when the state changes, not on a clock: `updated_at` of a turn that runs for minutes is its
/// start, a session at its prompt is `completed` with `live: false`, and a crash can leave `live: true` for good. So whether a
/// session is open is told by a gjc process running in its folder (`GjcScanner.liveFolders`), and the state file only says what it is
/// doing. `GjcScanner` finds those files for the folders of recent sessions, `GjcTracker` turns what it finds into board agents, and
/// `GjcWatcher` runs both while the count or the Agents tab is showing.
struct GjcSession: Equatable {
    let id: String
    let cwd: String
    let state: String
    let ready: Bool
}

struct GjcScanner {
    /// Session files and state files modified within this long ago name the folders looked in and the sessions that can be open.
    static let window: TimeInterval = 2 * 86_400
    static let maxFiles = 100
    /// How long the folders are kept before the session files are listed again.
    static let folderInterval: TimeInterval = 10

    /// How many gjc processes run in each folder, by path with links resolved. Tests give a made-up table.
    var runningFolders: @Sendable () -> [String: Int]

    private var folders: [String] = []
    private var listedAt: Date?
    /// The folder in the header of a session file, by path: it never changes.
    private var headers: [String: String] = [:]

    init(runningFolders: @escaping @Sendable () -> [String: Int] = GjcScanner.liveFolders) {
        self.runningFolders = runningFolders
    }

    /// The open sessions at `now`: in each folder a gjc process runs in, the most recently changed state files, as many as there are
    /// processes there (one that ended in an error, or whose process is gone, is not among them).
    mutating func scan(home: URL, now: Date) -> [GjcSession] {
        if listedAt.map({ now.timeIntervalSince($0) >= Self.folderInterval || now < $0 }) ?? true {
            folders = recentFolders(home: home, now: now)
            listedAt = now
        }
        let running = runningFolders()
        guard !running.isEmpty else { return [] }
        let files = FileManager.default
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var byFolder: [String: [(session: GjcSession, changed: Date)]] = [:]
        for folder in folders {
            let root = URL(fileURLWithPath: folder).appendingPathComponent(".gjc", isDirectory: true)
            for name in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix("_session-") && !name.contains("%") {
                let url = root.appendingPathComponent(name).appendingPathComponent("runtime/runtime-state.json")
                guard let modified = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      let data = try? Data(contentsOf: url),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = object["session_id"] as? String, Resume.isSafeSession(id),
                      let state = object["state"] as? String, state != "errored" else { continue }
                let updated = (object["updated_at"] as? String).flatMap(formatter.date(from:)) ?? modified
                let changed = max(modified, updated)
                let cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder
                guard now.timeIntervalSince(changed) <= Self.window,
                      let place = [folder, cwd].map(Self.resolved).first(where: { running[$0] != nil }) else { continue }
                byFolder[place, default: []].append((GjcSession(id: id, cwd: cwd, state: state, ready: object["ready_for_input"] as? Bool == true), changed))
            }
        }
        var found: [String: GjcSession] = [:]
        for (place, candidates) in byFolder {
            for candidate in candidates.sorted(by: { $0.changed > $1.changed }).prefix(running[place] ?? 0) { found[candidate.session.id] = candidate.session }
        }
        return found.values.sorted { $0.id < $1.id }
    }

    private static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// The folders the processes named `gjc` of this user run in, and how many in each.
    @Sendable static func liveFolders() -> [String: Int] {
        let size = MemoryLayout<pid_t>.size
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / size + 32)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * size))
        guard filled > 0 else { return [:] }
        var folders: [String: Int] = [:]
        for pid in pids.prefix(Int(filled) / size) where pid > 0 {
            var name = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "gjc" else { continue }
            var info = proc_vnodepathinfo()
            let length = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, length) == length else { continue }
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { folders[resolved(path), default: 0] += 1 }
        }
        return folders
    }

    /// The distinct folders of the newest session files of the last `window`.
    private mutating func recentFolders(home: URL, now: Date) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let cutoff = now.addingTimeInterval(-Self.window)
        var recent: [(url: URL, modified: Date)] = []
        for folder in PiSessions.folders(.gjc, home: home) {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
            where PiSessions.sessionID(fileName: url.lastPathComponent) != nil {
                if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                   let modified = values.contentModificationDate, modified >= cutoff { recent.append((url, modified)) }
            }
        }
        recent.sort { $0.modified > $1.modified }
        var folders: [String] = []
        for file in recent.prefix(Self.maxFiles) {
            if headers[file.url.path] == nil { headers[file.url.path] = Self.folder(inHeaderOf: file.url) ?? "" }
            if let folder = headers[file.url.path], !folder.isEmpty, !folders.contains(folder) { folders.append(folder) }
        }
        headers = headers.filter { path, _ in recent.contains { $0.url.path == path } }
        return folders
    }

    /// The `cwd` of the file's header line.
    static func folder(inHeaderOf url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: AgentTranscript.headWindow) else { return nil }
        try? handle.close()
        for line in data.split(separator: 0x0A).prefix(3) {
            if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], object["type"] as? String == "session",
               let cwd = object["cwd"] as? String, Resume.isSafeFolder(cwd), !PiSessions.isTeamWorker(folder: cwd) { return cwd }
        }
        return nil
    }
}

/// What the board shows for gjc's live sessions: working while it runs, asking while it needs the user, and, once a turn it was
/// seen working has ended, a finished hand that turns idle after `Herdr.doneWindow` as any other does. A session first seen at
/// its prompt is idle: Nunsseop didn't see it finish.
struct GjcTracker {
    private enum Phase { case working, asking, ready, idle }
    private struct Known {
        var phase: Phase
        var since: Date
    }

    private var known: [String: Known] = [:]

    mutating func agents(for sessions: [GjcSession], now: Date) -> [String: AgentBoard.Agent] {
        var next: [String: Known] = [:]
        var agents: [String: AgentBoard.Agent] = [:]
        for session in sessions {
            let before = known[session.id]
            let phase: Phase
            switch session.state {
            case "running": phase = .working
            case "needs_user_input": phase = .asking
            default:
                // At the prompt: finished when it was working or asking a moment ago, as it stays while it waits.
                phase = before.map { $0.phase == .working || $0.phase == .asking ? .ready : $0.phase } ?? .idle
            }
            let entry = Known(phase: phase, since: before?.phase == phase ? before!.since : now)
            next[session.id] = entry
            let state: AgentBoard.State = phase == .working ? .working : phase == .asking || phase == .ready ? .waiting : .idle
            agents[session.id] = AgentBoard.Agent(
                state: state, since: entry.since, finished: phase == .ready, tool: AgentKind.gjc.rawValue, cwd: session.cwd,
                session: session.id, idleFrom: phase == .ready ? entry.since.addingTimeInterval(Herdr.doneWindow) : nil)
        }
        known = next
        return agents
    }
}

/// Polls gjc's state files every `interval` while `isOn` says the count or the tab is showing, off the main thread, one scan
/// at a time.
@MainActor
final class GjcWatcher {
    static let interval: TimeInterval = 2
    static let source = "gjc"

    private let board: AgentBoard
    private let isOn: () -> Bool
    private let home: URL
    private let now: () -> Date
    private var scanner: GjcScanner
    private var tracker = GjcTracker()
    /// What the board was last given, so it is told only of a change: every update wakes the Agents tab.
    private var published: [String: AgentBoard.Agent] = [:]
    private var timer: Timer?
    private var scanning = false
    /// Bumped by `reset`, so a scan that began before it is not applied.
    private var generation = 0
    private let queue = DispatchQueue(label: "nunsseop.gjc", qos: .utility)

    init(board: AgentBoard, isOn: @escaping () -> Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         now: @escaping () -> Date = { .now }, runningFolders: @escaping @Sendable () -> [String: Int] = GjcScanner.liveFolders) {
        self.scanner = GjcScanner(runningFolders: runningFolders)
        self.board = board
        self.isOn = isOn
        self.home = home
        self.now = now
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

    /// Forgets everything, once the count isn't shown any more.
    func reset() {
        generation += 1
        tracker = GjcTracker()
        publish([:])
    }

    private func publish(_ agents: [String: AgentBoard.Agent], at moment: Date = .now) {
        guard agents != published else { return }
        published = agents
        board.replace(source: Self.source, with: agents, now: moment)
    }

    /// One look, when the count or the tab is showing and gjc has been used on this Mac.
    func poll() {
        guard isOn(), FileManager.default.fileExists(atPath: home.appendingPathComponent(".gjc").path) else {
            if !scanning { publish([:]) }
            return
        }
        guard !scanning else { return }
        scanning = true
        let (generation, moment, home) = (generation, now(), home)
        var scanner = scanner
        queue.async { [weak self] in
            let sessions = scanner.scan(home: home, now: moment)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(sessions, scanner: scanner, generation: generation, at: moment) }
            }
        }
    }

    private func finish(_ sessions: [GjcSession], scanner: GjcScanner, generation: Int, at moment: Date) {
        scanning = false
        self.scanner = scanner
        guard generation == self.generation else { return }
        publish(tracker.agents(for: sessions, now: moment), at: moment)
    }
}
