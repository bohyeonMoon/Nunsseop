import AppKit
import Darwin

/// Paseo (paseo.sh) runs coding agents (Claude Code through the Claude Agent SDK, Codex through `codex app-server`, OpenCode, pi...)
/// in a local daemon that its desktop app and its `paseo` command line talk to. None of that is installed here to look at, so every
/// fact below is read from its source (github.com/getpaseo/paseo, packages/...) and checked against fixtures:
/// - the daemon keeps `$PASEO_HOME/paseo.pid` (`pid`, `startedAt`, `listen`, `serverId`) while it runs, and one JSON record per
///   agent in `agents/<cwd with dashes>/<id>.json` (server/src/server/agent/agent-storage.ts), rewritten when an agent's state
///   changes, not on a clock; `lastStatus` is `initializing`, `idle`, `running`, `error` or `closed`;
/// - it listens on `127.0.0.1:6767` unless told otherwise, and takes a WebSocket at `/ws` (see `PaseoWire`);
/// - the desktop app is `sh.paseo.desktop`, registers the `paseo:` scheme, and opens an agent at `paseo://h/<server id>/agent/<agent id>`
///   (protocol/src/agent-deep-link.ts, desktop/electron-builder.yml); the command line is inside it at `Contents/Resources/bin/paseo`.
/// Nothing here starts the daemon, the app or a terminal.
enum Paseo {
    /// The board's source name.
    static let source = "paseo"
    static let bundleID = "sh.paseo.desktop"
    /// What a card or a row calls it.
    static let name = "Paseo"
    static let defaultPort = 6767
    /// A working agent whose record hasn't been written for this long stops being listed. A worker that died mid-turn (a crash, the
    /// system killing it) leaves `running` in the record, and the supervisor that owns the pid file stays up and says nothing of it.
    static let staleWorking: TimeInterval = 6 * 60 * 60
    /// Paseo's own names for the tools it runs where they differ from how `AgentKind` names them.
    private static let providerNames = ["copilot": "Copilot"]

    static func folder(home: URL) -> URL { home.appendingPathComponent(".paseo", isDirectory: true) }

    /// The desktop app, wherever it is installed.
    static func appURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications/Paseo.app", home.appendingPathComponent("Applications/Paseo.app").path]
            .first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Whether Paseo has been used on this Mac: its folder is there, or its app is installed.
    static func isPresent(home: URL = FileManager.default.homeDirectoryForCurrentUser, appInstalled: () -> Bool = { appURL() != nil }) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder(home: home).path, isDirectory: &isDirectory), isDirectory.boolValue { return true }
        return appInstalled()
    }

    /// The command line: the one inside the app first (it is the version of the daemon the app runs), then the places a global
    /// install puts it. It is run with arguments only, never through a shell.
    static func cli(home: URL = FileManager.default.homeDirectoryForCurrentUser, app: URL? = appURL(),
                    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        var paths = app.map { [$0.appendingPathComponent("Contents/Resources/bin/paseo").path] } ?? []
        paths += [".local/bin", ".npm-global/bin", ".bun/bin", ".volta/bin"].map { home.appendingPathComponent($0).appendingPathComponent("paseo").path }
        paths += ["/opt/homebrew/bin/paseo", "/usr/local/bin/paseo"]
        return paths.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// The search path the command line runs with. An app has the system's minimal one, and a command line installed with npm starts
    /// `node` from `/usr/bin/env`: the folder of the command line itself (where nvm, fnm, Volta and Homebrew put `node` beside it)
    /// and the usual places come first.
    static func path(for cli: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        ([cli.deletingLastPathComponent().path, home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
    }

    /// One call of the command line: its arguments, and the path it finds `node` by.
    static func run(_ cli: URL, _ arguments: [String]) -> AgentStep {
        .runWith(cli, arguments, variables: ["PATH": path(for: cli)])
    }

    /// An agent or server id as it goes into an argument or a link: plain characters, and no dash first, which the command line would
    /// take for an option.
    static func isSafeID(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count), let first = value.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic || ("0"..."9").contains(first) else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// The link that opens an agent in the desktop app. nil when either id is not plain.
    static func deepLink(server: String?, agent: String) -> URL? {
        guard let server, isSafeID(server), isSafeID(agent) else { return nil }
        return URL(string: "paseo://h/\(server)/agent/\(agent)")
    }

    /// The tool Paseo runs, as the board names it: `AgentKind`'s name where there is one, else Paseo's own label.
    static func tool(provider: String) -> String {
        let lowered = provider.lowercased()
        return AgentKind(tool: lowered)?.rawValue ?? providerNames[lowered] ?? provider
    }

    /// Opens the desktop app, on an agent when its link is known. `open -b` hands the link to the app that registered the scheme.
    static func openStep(server: String?, agent: String) -> AgentStep {
        .run(URL(fileURLWithPath: "/usr/bin/open"), ["-b", bundleID] + (deepLink(server: server, agent: agent).map { [$0.absoluteString] } ?? []))
    }

    /// When this Mac started, which tells a pid file left by a daemon that died with the previous boot.
    static func bootTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec))
    }

    @Sendable static func isAlive(_ pid: Int32) -> Bool { pid > 1 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// The daemon's id as it keeps it in `<home>/server-id` (server/src/server/server-id.ts), readable while the daemon is down: the link
    /// to an agent needs it then too. nil when the file is missing or not plain.
    static func storedServerID(home: URL) -> String? {
        guard let text = try? String(contentsOf: folder(home: home).appendingPathComponent("server-id"), encoding: .utf8) else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSafeID(id) ? id : nil
    }

    /// Whether the daemon has a password (`daemon.auth.password` in `config.json`). A password given in the daemon's environment can't
    /// be seen from here: the daemon says so itself, in answer to the hello (see `PaseoClient`).
    static func hasPassword(home: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder(home: home).appendingPathComponent("config.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = (object["daemon"] as? [String: Any])?["auth"] as? [String: Any],
              let password = auth["password"] as? String else { return false }
        return !password.isEmpty
    }
}

private let timestamp: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private func date(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    return timestamp.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

/// The running daemon, from its pid file.
struct PaseoDaemon: Equatable {
    struct Endpoint: Equatable {
        let host: String
        let port: Int
    }

    var pid: Int32
    var startedAt: Date?
    /// As the daemon wrote it: `host:port`, or the path of a socket.
    var listen: String?
    var serverID: String?
    /// The pid file says `"listen": null`: the supervisor is up and its worker is not (it is starting, or it died and is being started
    /// again, pid-lock.ts `updatePidLock` in `onWorkerExit`). No agent is running then, whatever the records say.
    var starting = false

    /// The daemon of `home`, when its process is alive and began after this boot (a pid is reused, and a crash leaves the file).
    static func read(home: URL, bootTime: Date? = Paseo.bootTime(), isAlive: (Int32) -> Bool = Paseo.isAlive) -> PaseoDaemon? {
        guard let data = try? Data(contentsOf: Paseo.folder(home: home).appendingPathComponent("paseo.pid")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = object["pid"] as? Int, let pid = Int32(exactly: number), isAlive(pid) else { return nil }
        let started = date(object["startedAt"])
        // The same allowance as Paseo's own check, for the whole seconds the boot time is given in.
        if let started, let bootTime, started < bootTime.addingTimeInterval(-5) { return nil }
        return PaseoDaemon(pid: pid, startedAt: started, listen: object["listen"] as? String, serverID: (object["serverId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                           starting: object["listen"] is NSNull)
    }

    /// Where it listens on TCP: nil for a socket or a pipe, which the app's WebSocket client doesn't reach, and while the worker isn't up.
    /// `127.0.0.1:6767` when the file has no `listen` at all.
    var endpoint: Endpoint? {
        guard !starting else { return nil }
        guard let listen, !listen.isEmpty else { return Endpoint(host: "127.0.0.1", port: Paseo.defaultPort) }
        guard !listen.hasPrefix("/"), !listen.hasPrefix("~"), !listen.contains("://"), !listen.hasPrefix("\\\\") else { return nil }
        if listen.allSatisfy(\.isNumber) { return Int(listen).flatMap { (1...65_535).contains($0) ? Endpoint(host: "127.0.0.1", port: $0) : nil } }
        guard let colon = listen.lastIndex(of: ":"), let port = Int(listen[listen.index(after: colon)...]), (1...65_535).contains(port) else { return nil }
        var host = String(listen[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return Endpoint(host: host.isEmpty ? "127.0.0.1" : host, port: port)
    }

    /// The WebSocket address, only when the daemon is on this Mac: a loopback address, or the wildcard one, which is reached through loopback.
    var webSocketURL: URL? {
        guard let endpoint else { return nil }
        let host: String
        switch endpoint.host.lowercased() {
        case "127.0.0.1", "localhost", "0.0.0.0": host = "127.0.0.1"
        case "::1", "::": host = "[::1]"
        default: return nil
        }
        return URL(string: "ws://\(host):\(endpoint.port)/ws")
    }
}

/// One agent's record file (`agents/<folder>/<id>.json`), reduced to what the board and the Recent list need.
struct PaseoRecord: Equatable {
    let id: String
    let provider: String
    let cwd: String
    var title: String?
    var status: String
    var updatedAt: Date
    var requiresAttention = false
    /// `finished` or `error`: why it wants a look, until someone looks at it in Paseo. The type allows `permission` too, but the daemon
    /// only broadcasts that one and never writes it.
    var attention: String?
    var attentionAt: Date?
    var archived = false
    /// A helper agent of Paseo's own (naming, summaries), which nobody started.
    var isInternal = false
    /// Started by another agent, which lists it under its own.
    var delegated = false
    var model: String?
    /// The tool's own session id (Claude Code's, Codex's thread): what the same session is told by elsewhere.
    var session: String?
    /// The handle `paseo import` takes to load the agent again.
    var persistedProvider: String?
    var persistedSession: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, Paseo.isSafeID(id), let provider = json["provider"] as? String, !provider.isEmpty,
              let cwd = json["cwd"] as? String, !cwd.isEmpty, let updated = date(json["updatedAt"]) ?? date(json["lastActivityAt"]) else { return nil }
        self.id = id
        self.provider = provider
        self.cwd = cwd
        updatedAt = updated
        status = json["lastStatus"] as? String ?? "closed"
        title = (json["title"] as? String).flatMap(AgentTranscript.cleanName)
        requiresAttention = json["requiresAttention"] as? Bool == true
        attention = json["attentionReason"] as? String
        attentionAt = date(json["attentionTimestamp"])
        archived = (json["archivedAt"] as? String).map { !$0.isEmpty } ?? false
        isInternal = json["internal"] as? Bool == true
        delegated = ((json["labels"] as? [String: Any])?["paseo.parent-agent-id"] as? String).map { !$0.isEmpty } ?? false
        let runtime = json["runtimeInfo"] as? [String: Any]
        let config = json["config"] as? [String: Any]
        model = [runtime?["model"], config?["model"]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
        let persistence = json["persistence"] as? [String: Any]
        persistedProvider = persistence?["provider"] as? String
        persistedSession = (persistence?["sessionId"] as? String).flatMap { Paseo.isSafeID($0) ? $0 : nil }
        session = [runtime?["sessionId"], persistence?["sessionId"]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
    }
}

/// Reads the agent records, off the main thread: a value type, so a scan can run on a copy. What was read from a file is kept until
/// its size or time changes, so a scan of a few thousand old records is a few thousand `stat`s.
struct PaseoScanner {
    /// Records last changed within this long ago are read; an older one is neither listed nor offered again.
    static let window = RecentConversations.window
    static let maxFiles = 4_000

    private struct Cached {
        var modified: Date
        var size: Int
        var record: PaseoRecord?
    }

    private var cache: [String: Cached] = [:]

    mutating func scan(home: URL, now: Date) -> [PaseoRecord] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isDirectoryKey]
        let root = Paseo.folder(home: home).appendingPathComponent("agents", isDirectory: true)
        let cutoff = now.addingTimeInterval(-Self.window)
        func children(_ url: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        }
        // Records sit in a folder named for the agent's own, and, in the first versions, straight in `agents`.
        var files: [(url: URL, modified: Date, size: Int)] = []
        for entry in children(root) {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let level = values?.isDirectory == true ? children(entry) : [entry]
            for url in level where url.pathExtension == "json" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= cutoff, let size = values.fileSize else { continue }
                files.append((url, modified, size))
            }
        }
        files.sort { $0.modified > $1.modified }
        var records: [PaseoRecord] = []
        var kept: [String: Cached] = [:]
        for file in files.prefix(Self.maxFiles) {
            let path = file.url.path
            var entry = cache[path]
            if entry?.modified != file.modified || entry?.size != file.size {
                let record = (try? Data(contentsOf: file.url))
                    .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.flatMap(PaseoRecord.init(json:))
                entry = Cached(modified: file.modified, size: file.size, record: record)
            }
            kept[path] = entry
            if let record = entry?.record { records.append(record) }
        }
        cache = kept
        return records
    }
}

/// What the board shows for Paseo's agents.
///
/// A record says `running` for as long as the agent works, but one written before the daemon began is a turn that died with it, so
/// only a record at least as new as the daemon counts as working, and not while the daemon's worker is down. That is a guess the
/// pid file can't settle (it is the supervisor's, which outlives a worker that crashed), so a working row nobody wrote a record for in
/// `Paseo.staleWorking` is let go. A turn that waits on a permission is asking, which only the daemon says (`pending`, from its
/// WebSocket): the record never does, so with the connection off such an agent reads as working. A finished or failed turn nobody has
/// looked at in Paseo (`requiresAttention`) is a hand that turns idle after `Herdr.doneWindow`, as a herdr pane's does; looking at it in
/// Paseo clears the flag. The daemon sets that flag once, at the first finish, and a message sent from the notch starts another turn
/// without clearing it, so the finish is dated by the record's last write when that is later. Archived and closed agents, Paseo's own
/// helpers, and everything while the daemon is down are not listed.
struct PaseoTracker {
    /// When each agent was first seen asking: the record doesn't say.
    private var asking: [String: Date] = [:]

    mutating func agents(_ records: [PaseoRecord], daemon: PaseoDaemon?, pending: Set<String> = [], cli: URL?, now: Date) -> [String: AgentBoard.Agent] {
        guard let daemon else {
            asking = [:]
            return [:]
        }
        var result: [String: AgentBoard.Agent] = [:]
        var stillAsking: [String: Date] = [:]
        for record in records where !record.archived && !record.isInternal && record.status != "closed" {
            let running = record.status == "running" || record.status == "initializing"
            let live = running && !daemon.starting && (daemon.startedAt.map { record.updatedAt >= $0.addingTimeInterval(-5) } ?? true)
            let asks = pending.contains(record.id)
            let seen = min(record.updatedAt, now)
            var agent = AgentBoard.Agent(
                state: .idle, since: seen, tool: Paseo.tool(provider: record.provider), app: Paseo.bundleID, cwd: record.cwd,
                session: record.session, input: cli == nil ? nil : .paseo(agent: record.id, server: daemon.serverID), title: record.title,
                model: record.model, host: Paseo.name)
            if asks {
                let since = asking[record.id] ?? now
                stillAsking[record.id] = since
                (agent.state, agent.since) = (.waiting, since)
            } else if live {
                (agent.state, agent.since) = (.working, seen)
                agent.expiresAt = seen.addingTimeInterval(Paseo.staleWorking)
            } else if record.requiresAttention, record.attention == "finished" || record.attention == "error" {
                let since = min(max(record.attentionAt ?? record.updatedAt, record.updatedAt), now)
                (agent.state, agent.finished, agent.since) = (.waiting, true, since)
                agent.idleFrom = since.addingTimeInterval(Herdr.doneWindow)
                agent.expiresAt = since.addingTimeInterval(AgentBoard.recentWindow)
            } else {
                agent.expiresAt = seen.addingTimeInterval(AgentBoard.recentWindow)
            }
            result[record.id] = agent
        }
        asking = stillAsking
        return result
    }
}

/// An agent of Paseo that is not open, to bring back from the Recent list.
struct PaseoResume: Equatable {
    let agent: String
    let provider: String
    let session: String
    let cwd: String
    /// Archived in Paseo: `paseo import` loads it again (it is the one command that does, and it refuses an agent that isn't
    /// archived: server/src/server/agent/import-sessions.ts); any other is opened in the app as it is.
    let archived: Bool
    let server: String?
    /// Whether the daemon is running. `paseo import` talks to it and never starts one (cli/src/utils/client.ts), and the app does.
    var daemonUp = true

    /// The agent is archived and the daemon is down: all that can be done is to start the app, and the click is for again once it has.
    var needsDaemon: Bool { archived && !daemonUp }

    /// The calls that bring it back and show it: `paseo import` for an archived one, then the app on the agent. With the daemon down
    /// the app alone, which starts it. nil when the command line is needed and isn't there.
    func steps(cli: URL?) -> [AgentStep]? {
        var steps: [AgentStep] = []
        if needsDaemon { return [Paseo.openStep(server: nil, agent: agent)] }
        if archived {
            guard let cli else { return nil }
            steps.append(Paseo.run(cli, ["import", session, "--provider", provider, "--cwd=\(cwd)"]))
        }
        return steps + [Paseo.openStep(server: server, agent: agent)]
    }
}

enum PaseoRecents {
    /// The tools' recent conversations and Paseo's together, newest first and no more than `limit`. A session that is both a file of
    /// the tool and an agent of Paseo is the agent: Paseo is where it is brought back.
    static func merged(_ tools: [RecentConversation], _ paseo: [RecentConversation], limit: Int = RecentConversations.limit) -> [RecentConversation] {
        guard !paseo.isEmpty else { return tools }
        let sessions = Set(paseo.map { $0.session.lowercased() })
        return Array((tools.filter { !sessions.contains($0.session.lowercased()) } + paseo)
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.id < $1.id }.prefix(limit))
    }

    /// Paseo's agents that are not open, the most recently used first: those with a session to load again, in a folder that is still
    /// there, that nobody started on another agent's behalf.
    /// - open: the ids of the agents on the board, and the session ids of the sessions open anywhere.
    /// - daemonUp: whether the daemon is running (see `PaseoResume.daemonUp`).
    static func list(_ records: [PaseoRecord], excluding open: Set<String>, server: String?, daemonUp: Bool = true, now: Date, scratch: [String] = RecentConversations.scratch,
                     limit: Int = RecentConversations.limit) -> [RecentConversation] {
        let cutoff = now.addingTimeInterval(-RecentConversations.window)
        var found: [RecentConversation] = []
        for record in records.sorted(by: { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }) where found.count < limit {
            guard !record.isInternal, !record.delegated, record.updatedAt >= cutoff, let provider = record.persistedProvider,
                  let session = record.persistedSession, !open.contains(record.id), !open.contains(session.lowercased()),
                  RecentConversations.isResumableFolder(record.cwd, scratch: scratch) else { continue }
            var conversation = RecentConversation(kind: AgentKind(tool: record.provider) ?? .claude, session: session, cwd: record.cwd,
                                                  modified: record.updatedAt, name: record.title)
            conversation.paseo = PaseoResume(agent: record.id, provider: provider, session: session, cwd: record.cwd, archived: record.archived, server: server, daemonUp: daemonUp)
            found.append(conversation)
        }
        return found
    }
}
