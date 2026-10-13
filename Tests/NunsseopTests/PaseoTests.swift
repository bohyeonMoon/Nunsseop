import Foundation
import Testing
@testable import Nunsseop

// Paseo support. Its daemon and app are not installed where these run: the fixtures are shaped like the types in its source
// (agent-storage.ts `STORED_AGENT_SCHEMA`, pid-lock.ts `pidLockInfoSchema`, protocol/src/messages.ts) and nothing here starts a process
// or reaches a network but a made-up server on the loopback.

let paseoStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
let paseoAgentID = "6f1b2c3d-0000-4000-8000-000000000001"
let paseoSessionID = "5f0c2d1e-0000-4000-8000-000000000001"
let paseoCLI = URL(fileURLWithPath: "/Applications/Paseo.app/Contents/Resources/bin/paseo")

func paseoStamp(_ date: Date) -> String {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format.string(from: date)
}

func orNull(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

/// One agent's record file as the daemon writes it.
func paseoRecord(id: String = paseoAgentID, provider: String = "claude", cwd: String = "/Users/me/work/api", status: String = "idle",
                    updated: Date = paseoStart, title: String? = "Fix the build", attention: String? = nil, attentionAt: Date? = nil,
                    archived: Bool = false, helper: Bool = false, session: String? = paseoSessionID, parent: String? = nil,
                    model: String? = "claude-opus-5-5") -> [String: Any] {
    var object: [String: Any] = [
        "id": id, "provider": provider, "cwd": cwd, "workspaceId": "ws_1", "createdAt": paseoStamp(updated.addingTimeInterval(-600)),
        "updatedAt": paseoStamp(updated), "lastActivityAt": paseoStamp(updated), "lastUserMessageAt": paseoStamp(updated), "title": orNull(title),
        "labels": parent.map { ["paseo.parent-agent-id": $0] } ?? [:], "lastStatus": status, "lastModeId": "default",
        "config": ["modeId": "default", "model": orNull(model)], "requiresAttention": attention != nil,
        "attentionReason": orNull(attention), "attentionTimestamp": orNull(attentionAt.map(paseoStamp)),
    ]
    if let session {
        object["runtimeInfo"] = ["provider": provider, "sessionId": session, "model": orNull(model), "modeId": "default"]
        object["persistence"] = ["provider": provider, "sessionId": session]
    }
    if helper { object["internal"] = true }
    if archived { object["archivedAt"] = paseoStamp(updated) }
    return object
}

func paseoDecoded(_ object: [String: Any]) -> PaseoRecord? { PaseoRecord(json: object) }

/// A scratch home with Paseo's folder in it: the daemon's pid file and the agents' records.
final class PaseoHome {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-paseo-\(UUID().uuidString.prefix(8))")
    private let files = FileManager.default

    init() { try? files.createDirectory(at: url.appendingPathComponent(".paseo/agents"), withIntermediateDirectories: true) }
    deinit { try? files.removeItem(at: url) }

    func work(_ name: String) -> String {
        let path = url.appendingPathComponent("work/\(name)").path
        try? files.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func daemon(pid: Int = Int(ProcessInfo.processInfo.processIdentifier), started: Date = paseoStart.addingTimeInterval(-3_600),
                listen: Any = "127.0.0.1:6767", serverID: String? = "srv_abc123") {
        var object: [String: Any] = ["pid": pid, "startedAt": paseoStamp(started), "hostname": "mac", "uid": 501, "listen": listen]
        if let serverID { object["serverId"] = serverID }
        write(object, to: ".paseo/paseo.pid")
    }

    func config(_ object: [String: Any]) { write(object, to: ".paseo/config.json") }

    /// A record in the folder named for the agent's place, `ago` seconds old on disk.
    func agent(_ object: [String: Any], folder: String? = "-Users-me-work-api", ago: TimeInterval = 0, now: Date = paseoStart) {
        let id = object["id"] as! String
        write(object, to: ".paseo/agents/" + (folder.map { "\($0)/" } ?? "") + "\(id).json")
        let path = url.appendingPathComponent(".paseo/agents/" + (folder.map { "\($0)/" } ?? "") + "\(id).json").path
        try? files.setAttributes([.modificationDate: now.addingTimeInterval(-ago)], ofItemAtPath: path)
    }

    private func write(_ object: [String: Any], to path: String) {
        let file = url.appendingPathComponent(path)
        try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: object).write(to: file)
    }
}

struct PaseoFactsTests {
    @Test func theAppAndItsLinkAreTheOnesInItsSource() {
        // desktop/electron-builder.yml `appId`, and the fixture of desktop/src/agent-navigation.test.ts.
        #expect(Paseo.bundleID == "sh.paseo.desktop")
        #expect(Paseo.deepLink(server: "server-1", agent: "agent-2")?.absoluteString == "paseo://h/server-1/agent/agent-2")
        #expect(Paseo.deepLink(server: nil, agent: "agent-2") == nil)
        #expect(Paseo.deepLink(server: "srv/../x", agent: "a") == nil)
        #expect(Paseo.deepLink(server: "srv", agent: "a b") == nil)
    }

    @Test func anIdThatCouldBeAnOptionOrAPathIsNotPlain() {
        #expect(Paseo.isSafeID(paseoAgentID) && Paseo.isSafeID("agent_sdk") && Paseo.isSafeID("srv.1-2_3"))
        for bad in ["", "-x", "--prompt=x", "../x", "a/b", "a b", "a\nb", "$(id)", "é", String(repeating: "a", count: 129)] {
            #expect(!Paseo.isSafeID(bad), Comment(rawValue: bad))
        }
    }

    @Test func theCommandLineIsLookedForInTheAppFirstThenWhereAGlobalInstallPutsIt() {
        let home = URL(fileURLWithPath: "/Users/me")
        let app = URL(fileURLWithPath: "/Applications/Paseo.app")
        let everywhere = { (_: String) in true }
        #expect(Paseo.cli(home: home, app: app, isExecutable: everywhere)?.path == "/Applications/Paseo.app/Contents/Resources/bin/paseo")
        #expect(Paseo.cli(home: home, app: nil, isExecutable: everywhere)?.path == "/Users/me/.local/bin/paseo")
        for place in ["/Users/me/.npm-global/bin/paseo", "/Users/me/.bun/bin/paseo", "/Users/me/.volta/bin/paseo", "/opt/homebrew/bin/paseo", "/usr/local/bin/paseo"] {
            #expect(Paseo.cli(home: home, app: nil, isExecutable: { $0 == place })?.path == place, Comment(rawValue: place))
        }
        #expect(Paseo.cli(home: home, app: app, isExecutable: { _ in false }) == nil)
    }

    @Test func theProvidersAreNamedAsTheBoardNamesTools() {
        #expect(Paseo.tool(provider: "claude") == "claude" && Paseo.tool(provider: "codex") == "codex" && Paseo.tool(provider: "opencode") == "opencode")
        #expect(Paseo.tool(provider: "pi") == "pi" && Paseo.tool(provider: "omp") == "omp")
        #expect(Paseo.tool(provider: "copilot") == "Copilot" && Paseo.tool(provider: "somethingnew") == "somethingnew")
    }

    @Test func paseoIsPresentWhereItsFolderIsOrItsAppIs() {
        let home = PaseoHome()
        #expect(Paseo.isPresent(home: home.url, appInstalled: { false }))
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-bare-\(UUID().uuidString.prefix(8))")
        #expect(!Paseo.isPresent(home: bare, appInstalled: { false }) && Paseo.isPresent(home: bare, appInstalled: { true }))
    }

    @Test func theCommandLineRunsWithAPathThatFindsNodeBesideIt() {
        // An app starts with the system's minimal path, and a command line installed with npm starts `node` through it.
        let nvm = URL(fileURLWithPath: "/Users/me/.nvm/versions/node/v22/bin/paseo")
        let expected = "/Users/me/.nvm/versions/node/v22/bin:/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        #expect(Paseo.path(for: nvm, home: URL(fileURLWithPath: "/Users/me")) == expected)
        #expect(Paseo.run(nvm, ["ls"]) == .runWith(nvm, ["ls"], variables: ["PATH": Paseo.path(for: nvm)]))
        #expect(Paseo.path(for: paseoCLI, home: URL(fileURLWithPath: "/Users/me")).hasPrefix("/Applications/Paseo.app/Contents/Resources/bin:"))
    }

    @Test func theOpenStepHandsTheLinkToTheApp() {
        #expect(Paseo.openStep(server: "srv", agent: "a1") == .run(URL(fileURLWithPath: "/usr/bin/open"), ["-b", "sh.paseo.desktop", "paseo://h/srv/agent/a1"]))
        #expect(Paseo.openStep(server: nil, agent: "a1") == .run(URL(fileURLWithPath: "/usr/bin/open"), ["-b", "sh.paseo.desktop"]))
    }
}

struct PaseoRecordTests {
    @Test func aRecordIsReadAsTheDaemonWritesIt() throws {
        let object = paseoRecord(status: "running", updated: paseoStart, attention: "permission", attentionAt: paseoStart.addingTimeInterval(5))
        let parsed = try #require(paseoDecoded(object))
        #expect(parsed.id == paseoAgentID && parsed.provider == "claude" && parsed.cwd == "/Users/me/work/api")
        #expect(parsed.title == "Fix the build" && parsed.status == "running" && parsed.model == "claude-opus-5-5")
        #expect(abs(parsed.updatedAt.timeIntervalSince(paseoStart)) < 0.001)
        #expect(parsed.requiresAttention && parsed.attention == "permission" && abs((parsed.attentionAt ?? .distantPast).timeIntervalSince(paseoStart) - 5) < 0.001)
        #expect(!parsed.archived && !parsed.isInternal && !parsed.delegated)
        #expect(parsed.session == paseoSessionID && parsed.persistedProvider == "claude" && parsed.persistedSession == paseoSessionID)
    }

    @Test func theFlagsThatKeepAnAgentOffTheBoardAreRead() throws {
        #expect(try #require(paseoDecoded(paseoRecord(archived: true))).archived)
        #expect(try #require(paseoDecoded(paseoRecord(helper: true))).isInternal)
        #expect(try #require(paseoDecoded(paseoRecord(parent: "6f1b2c3d-0000-4000-8000-0000000000ff"))).delegated)
    }

    @Test func aRecordWithoutASessionOrATitleStillReads() throws {
        let parsed = try #require(paseoDecoded(paseoRecord(title: nil, session: nil)))
        #expect(parsed.title == nil && parsed.session == nil && parsed.persistedSession == nil)
        // The null the daemon writes for a missing title.
        var object = paseoRecord()
        object["title"] = NSNull()
        #expect(try #require(paseoDecoded(object)).title == nil)
        // The runtime's session id stands in for the persistence handle, which names only what `paseo import` takes.
        var runtimeOnly = paseoRecord()
        runtimeOnly["persistence"] = nil
        let runtime = try #require(paseoDecoded(runtimeOnly))
        #expect(runtime.session == paseoSessionID && runtime.persistedSession == nil)
    }

    @Test func aTitleIsCleanedForOneLine() throws {
        #expect(try #require(paseoDecoded(paseoRecord(title: "  Fix\nthe\tbuild  "))).title == "Fix the build")
    }

    @Test func recordsThatCannotBeTrustedAreRefused() {
        var noCwd = paseoRecord(); noCwd["cwd"] = nil
        var noProvider = paseoRecord(); noProvider["provider"] = ""
        var noTime = paseoRecord(); noTime["updatedAt"] = nil; noTime["lastActivityAt"] = nil
        for bad in [paseoRecord(id: "../etc/passwd"), paseoRecord(id: "-rf"), noCwd, noProvider, noTime] { #expect(paseoDecoded(bad) == nil) }
        // A status the daemon does not know is closed, as its own default says.
        var unknown = paseoRecord(); unknown["lastStatus"] = nil
        #expect(paseoDecoded(unknown)?.status == "closed")
    }

    @Test func aSessionIdWithAnOptionInItIsNotKeptForTheCommandLine() throws {
        let parsed = try #require(paseoDecoded(paseoRecord(session: "--help")))
        #expect(parsed.persistedSession == nil)
    }
}

struct PaseoDaemonTests {
    private let boot = paseoStart.addingTimeInterval(-86_400)

    @Test func aRunningDaemonIsReadFromItsPidFile() throws {
        let home = PaseoHome()
        home.daemon()
        let daemon = try #require(PaseoDaemon.read(home: home.url, bootTime: boot, isAlive: { _ in true }))
        #expect(daemon.pid == Int32(ProcessInfo.processInfo.processIdentifier) && daemon.serverID == "srv_abc123" && daemon.listen == "127.0.0.1:6767")
        #expect(abs((daemon.startedAt ?? .distantPast).timeIntervalSince(paseoStart.addingTimeInterval(-3_600))) < 0.001)
        #expect(daemon.endpoint == PaseoDaemon.Endpoint(host: "127.0.0.1", port: 6767))
        #expect(daemon.webSocketURL?.absoluteString == "ws://127.0.0.1:6767/ws")
    }

    @Test func aDeadProcessOrAFileFromBeforeThisBootIsNoDaemon() {
        let home = PaseoHome()
        home.daemon()
        #expect(PaseoDaemon.read(home: home.url, bootTime: boot, isAlive: { _ in false }) == nil)
        #expect(PaseoDaemon.read(home: home.url, bootTime: paseoStart, isAlive: { _ in true }) == nil)
        #expect(PaseoDaemon.read(home: home.url, bootTime: nil, isAlive: { _ in true }) != nil)
        let none = PaseoHome()
        #expect(PaseoDaemon.read(home: none.url, bootTime: boot, isAlive: { _ in true }) == nil)
        let junk = PaseoHome()
        try? Data("not json".utf8).write(to: junk.url.appendingPathComponent(".paseo/paseo.pid"))
        #expect(PaseoDaemon.read(home: junk.url, bootTime: boot, isAlive: { _ in true }) == nil)
    }

    @Test func whereItListensDecidesWhetherNunsseopReachesIt() {
        func url(_ listen: String?) -> String? { PaseoDaemon(pid: 1, listen: listen).webSocketURL?.absoluteString }
        // The default when the file says nothing, a bare port, and a host with its port.
        #expect(url(nil) == "ws://127.0.0.1:6767/ws" && url("6868") == "ws://127.0.0.1:6868/ws" && url("127.0.0.1:7000") == "ws://127.0.0.1:7000/ws")
        #expect(url("localhost:7000") == "ws://127.0.0.1:7000/ws" && url("0.0.0.0:7000") == "ws://127.0.0.1:7000/ws")
        #expect(url("[::1]:7000") == "ws://[::1]:7000/ws" && url("[::]:7000") == "ws://[::1]:7000/ws")
        // A socket, a pipe, another machine's address and nonsense are not reached.
        for other in ["/Users/me/.paseo/paseo.sock", "unix:///tmp/p.sock", "~/p.sock", "pipe://x", "\\\\.\\pipe\\paseo", "192.168.1.5:6767", "example.com:6767", "127.0.0.1:0",
                      "127.0.0.1:70000", "127.0.0.1:x", "nonsense"] {
            #expect(url(other) == nil, Comment(rawValue: other))
        }
    }

    @Test func aPidFileWithNoListenAddressIsASupervisorWithoutAWorker() throws {
        let home = PaseoHome()
        home.daemon(listen: NSNull())
        let daemon = try #require(PaseoDaemon.read(home: home.url, bootTime: boot, isAlive: { _ in true }))
        #expect(daemon.starting && daemon.listen == nil && daemon.endpoint == nil && daemon.webSocketURL == nil)
        // Not a daemon on a socket, which Settings says it can't reach.
        #expect(PaseoStatus.current(home: home.url, app: nil, isAlive: { _ in true }, bootTime: nil, refused: false).approvalsAvailable)
        home.daemon()
        #expect(try #require(PaseoDaemon.read(home: home.url, bootTime: boot, isAlive: { _ in true })).starting == false)
    }

    @Test func theServerIdIsReadFromItsFileWhileTheDaemonIsDown() throws {
        let home = PaseoHome()
        #expect(Paseo.storedServerID(home: home.url) == nil)
        let file = home.url.appendingPathComponent(".paseo/server-id")
        try Data("srv_abc123\n".utf8).write(to: file)
        #expect(Paseo.storedServerID(home: home.url) == "srv_abc123")
        try Data("--not plain\n".utf8).write(to: file)
        #expect(Paseo.storedServerID(home: home.url) == nil)
        try Data("\n".utf8).write(to: file)
        #expect(Paseo.storedServerID(home: home.url) == nil)
    }

    @Test func aRefusalFromTheDaemonIsInTheStatus() {
        let home = PaseoHome()
        home.daemon()
        // A password in the daemon's environment shows in no file: only its answer to the hello says so.
        #expect(PaseoStatus.current(home: home.url, app: nil, isAlive: { _ in true }, bootTime: nil, refused: false).approvalsAvailable)
        let status = PaseoStatus.current(home: home.url, app: nil, isAlive: { _ in true }, bootTime: nil, refused: true)
        #expect(!status.approvalsAvailable && status.daemonRunning)
    }

    @Test func aPasswordInTheConfigIsSeen() {
        let home = PaseoHome()
        #expect(!Paseo.hasPassword(home: home.url))
        home.config(["daemon": ["listen": "127.0.0.1:6767"]])
        #expect(!Paseo.hasPassword(home: home.url))
        home.config(["daemon": ["auth": ["password": ""]]])
        #expect(!Paseo.hasPassword(home: home.url))
        home.config(["daemon": ["auth": ["password": "$2b$12$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ0123456"]]])
        #expect(Paseo.hasPassword(home: home.url))
    }

    @Test func theStatusSaysWhatIsThereAndWhatIsNot() {
        let home = PaseoHome()
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-none-\(UUID().uuidString.prefix(8))")
        #expect(PaseoStatus.current(home: absent, app: nil, isAlive: { _ in true }, bootTime: nil, refused: false) == PaseoStatus())
        #expect(PaseoStatus.current(home: home.url, app: nil, isAlive: { _ in true }, bootTime: nil, refused: false)
                == PaseoStatus(present: true, daemonRunning: false, cliFound: false, approvalsAvailable: true))
        home.daemon()
        let app = URL(fileURLWithPath: "/nonexistent/Paseo.app")
        #expect(PaseoStatus.current(home: home.url, app: app, isAlive: { _ in true }, bootTime: nil, refused: false).daemonRunning)
        home.daemon(listen: "/tmp/p.sock")
        #expect(!PaseoStatus.current(home: home.url, app: nil, isAlive: { _ in true }, bootTime: nil, refused: false).approvalsAvailable)
        home.daemon()
        home.config(["daemon": ["auth": ["password": "x"]]])
        #expect(!PaseoStatus.current(home: home.url, app: nil, isAlive: { _ in true }, bootTime: nil, refused: false).approvalsAvailable)
    }
}

struct PaseoScannerTests {
    @Test func recordsAreFoundInTheFolderOfTheirPlaceAndAtTheTopLevel() {
        let home = PaseoHome()
        home.agent(paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000001"))
        home.agent(paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000002", cwd: "/Users/me/work/site"), folder: "-Users-me-work-site")
        home.agent(paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000003"), folder: nil)
        var scanner = PaseoScanner()
        let found = scanner.scan(home: home.url, now: paseoStart)
        #expect(Set(found.map(\.id)) == ["aaaaaaaa-0000-4000-8000-000000000001", "aaaaaaaa-0000-4000-8000-000000000002", "aaaaaaaa-0000-4000-8000-000000000003"])
    }

    @Test func aRecordOlderThanTheWindowOrNotARecordIsLeftOut() throws {
        let home = PaseoHome()
        home.agent(paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000001"), ago: PaseoScanner.window + 60)
        home.agent(paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000002"), ago: 60)
        let folder = home.url.appendingPathComponent(".paseo/agents/-Users-me-work-api")
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("aaaaaaaa-0000-4000-8000-000000000003.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        var scanner = PaseoScanner()
        #expect(scanner.scan(home: home.url, now: paseoStart).map(\.id) == ["aaaaaaaa-0000-4000-8000-000000000002"])
    }

    @Test func aRecordIsReadAgainOnlyWhenItsFileChanged() {
        let home = PaseoHome()
        home.agent(paseoRecord(status: "running"), ago: 120)
        var scanner = PaseoScanner()
        #expect(scanner.scan(home: home.url, now: paseoStart).first?.status == "running")
        // The same size and time: the cache answers, whatever the file holds now.
        let file = home.url.appendingPathComponent(".paseo/agents/-Users-me-work-api/\(paseoAgentID).json")
        let before = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        try? Data((String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)).replacingOccurrences(of: "running", with: "RUNNING").utf8).write(to: file)
        try? FileManager.default.setAttributes([.modificationDate: before as Any], ofItemAtPath: file.path)
        #expect(scanner.scan(home: home.url, now: paseoStart).first?.status == "running")
        home.agent(paseoRecord(status: "idle"), ago: 30)
        #expect(scanner.scan(home: home.url, now: paseoStart).first?.status == "idle")
    }

    @Test func oneRecordIsFoundByItsIdAndNothingElseIs() {
        let home = PaseoHome()
        home.agent(paseoRecord())
        #expect(PaseoScanner.record(id: paseoAgentID, home: home.url)?.cwd == "/Users/me/work/api")
        #expect(PaseoScanner.record(id: "6f1b2c3d-0000-4000-8000-0000000000aa", home: home.url) == nil)
        #expect(PaseoScanner.record(id: "../config", home: home.url) == nil)
    }
}

struct PaseoBoardTests {
    private let daemon = PaseoDaemon(pid: 1, startedAt: paseoStart.addingTimeInterval(-3_600), listen: "127.0.0.1:6767", serverID: "srv_abc123")
    private let now = paseoStart.addingTimeInterval(60)

    private func agents(_ objects: [[String: Any]], daemon: PaseoDaemon? = nil, pending: Set<String> = [], cli: URL? = paseoCLI, tracker: inout PaseoTracker) -> [String: AgentBoard.Agent] {
        tracker.agents(objects.compactMap(paseoDecoded), daemon: daemon ?? self.daemon, pending: pending, cli: cli, now: now)
    }

    private func agents(_ objects: [[String: Any]], pending: Set<String> = [], cli: URL? = paseoCLI) -> [String: AgentBoard.Agent] {
        var tracker = PaseoTracker()
        return agents(objects, pending: pending, cli: cli, tracker: &tracker)
    }

    @Test func aRunningAgentWorksFromTheRecordsTime() throws {
        let agent = try #require(agents([paseoRecord(status: "running", updated: paseoStart)])[paseoAgentID])
        #expect(agent.state == .working && !agent.finished && agent.idleFrom == nil)
        #expect(agent.since == paseoStart && agent.expiresAt == paseoStart.addingTimeInterval(Paseo.staleWorking))
        #expect(agent.tool == "claude" && agent.app == "sh.paseo.desktop" && agent.cwd == "/Users/me/work/api" && agent.session == paseoSessionID)
        #expect(agent.title == "Fix the build" && agent.model == "claude-opus-5-5" && agent.host == "Paseo")
        #expect(agent.input == .paseo(agent: paseoAgentID, server: "srv_abc123") && agent.pid == nil)
        #expect(try #require(agents([paseoRecord(status: "initializing", updated: paseoStart)])[paseoAgentID]).state == .working)
    }

    @Test func aRunningRecordFromBeforeTheDaemonBeganIsATurnThatDiedWithIt() throws {
        let stale = paseoRecord(status: "running", updated: daemon.startedAt!.addingTimeInterval(-300))
        let agent = try #require(agents([stale])[paseoAgentID])
        #expect(agent.state == .idle && agent.expiresAt != nil)
        // A record written at the daemon's start, within the second its clock may differ by, still counts.
        #expect(try #require(agents([paseoRecord(status: "running", updated: daemon.startedAt!.addingTimeInterval(-3))])[paseoAgentID]).state == .working)
    }

    @Test func aPermissionAsksOnlyWhereTheDaemonSaysSo() throws {
        let told = try #require(agents([paseoRecord(status: "running")], pending: [paseoAgentID])[paseoAgentID])
        #expect(told.state == .waiting && !told.finished)
        // The daemon knows better than a record that lags.
        #expect(try #require(agents([paseoRecord(status: "idle")], pending: [paseoAgentID])[paseoAgentID]).state == .waiting)
        // The daemon never writes `permission` into a record (only `finished` and `error`: agent-manager.ts checkAndSetAttention), so
        // a record that says so, as none does, is not taken for a question: without the connection the agent reads as working.
        let marked = try #require(agents([paseoRecord(status: "running", attention: "permission", attentionAt: paseoStart)])[paseoAgentID])
        #expect(marked.state == .working && !marked.finished)
        #expect(try #require(agents([paseoRecord(status: "idle", attention: "permission", attentionAt: paseoStart)])[paseoAgentID]).state == .idle)
    }

    @MainActor @Test func aWorkingRowNobodyWroteForALongTimeIsLetGo() throws {
        // A worker killed mid-turn leaves `running` behind and the supervisor, whose pid file this is, goes on.
        let agent = try #require(agents([paseoRecord(status: "running", updated: paseoStart)])[paseoAgentID])
        let board = AgentBoard()
        board.replace(source: Paseo.source, with: [paseoAgentID: agent], now: now)
        #expect(board.entries(now: now).count == 1 && board.counts.working == 1)
        let later = paseoStart.addingTimeInterval(Paseo.staleWorking + 1)
        #expect(board.entries(now: later).isEmpty)
        board.recount(now: later)
        #expect(board.counts.isEmpty)
    }

    @Test func nothingWorksWhileTheDaemonsWorkerIsDown() throws {
        // `listen: null` in the pid file is the supervisor with no worker (it is starting, or it died and is being started again).
        var down = daemon
        down.starting = true
        var tracker = PaseoTracker()
        let agent = try #require(agents([paseoRecord(status: "running", updated: paseoStart)], daemon: down, tracker: &tracker)[paseoAgentID])
        #expect(agent.state == .idle)
    }

    @Test func howLongAnAgentHasAskedIsRememberedAcrossLooks() throws {
        var tracker = PaseoTracker()
        let running = try #require(paseoDecoded(paseoRecord(status: "running")))
        let first = try #require(tracker.agents([running], daemon: daemon, pending: [paseoAgentID], cli: paseoCLI, now: now)[paseoAgentID])
        let later = try #require(tracker.agents([running], daemon: daemon, pending: [paseoAgentID], cli: paseoCLI, now: now.addingTimeInterval(30))[paseoAgentID])
        #expect(first.since == now && later.since == now)
        // Answered, then asked again: counted from the new asking.
        _ = tracker.agents([running], daemon: daemon, pending: [], cli: paseoCLI, now: now.addingTimeInterval(40))
        let again = try #require(tracker.agents([running], daemon: daemon, pending: [paseoAgentID], cli: paseoCLI, now: now.addingTimeInterval(50))[paseoAgentID])
        #expect(again.since == now.addingTimeInterval(50))
    }

    @Test func aFinishedTurnNobodyLookedAtIsAHandThatGoesDownAfterTheDoneWindow() throws {
        let done = paseoStart.addingTimeInterval(-30)
        let agent = try #require(agents([paseoRecord(status: "idle", updated: done, attention: "finished", attentionAt: done)])[paseoAgentID])
        #expect(agent.state == .waiting && agent.finished && agent.since == done)
        #expect(agent.idleFrom == done.addingTimeInterval(Herdr.doneWindow) && agent.expiresAt == done.addingTimeInterval(AgentBoard.recentWindow))
        #expect(agent.effective(at: done.addingTimeInterval(Herdr.doneWindow + 1)).state == .idle)
        // A failed turn is the same hand; one the user has looked at in Paseo (no flag) is idle.
        let failed = try #require(agents([paseoRecord(status: "error", updated: done, attention: "error", attentionAt: done)])[paseoAgentID])
        #expect(failed.state == .waiting && failed.finished)
        let seen = try #require(agents([paseoRecord(status: "idle", updated: done)])[paseoAgentID])
        #expect(seen.state == .idle && seen.expiresAt == done.addingTimeInterval(AgentBoard.recentWindow) && seen.since == done)
    }

    @Test func aSecondFinishIsDatedFromTheRecordNotFromTheFirstOneTheFlagStillHolds() throws {
        // The daemon sets the flag at the first finish and nothing clears it when a message from the notch starts another turn, so the
        // timestamp stays the first finish's. The second finish, long after, must not read as an old hand that went idle.
        let first = paseoStart.addingTimeInterval(-3 * 3_600)
        let second = paseoStart.addingTimeInterval(30)
        let agent = try #require(agents([paseoRecord(status: "idle", updated: second, attention: "finished", attentionAt: first)])[paseoAgentID])
        #expect(agent.state == .waiting && agent.finished && agent.since == second)
        #expect(agent.idleFrom == second.addingTimeInterval(Herdr.doneWindow) && agent.expiresAt == second.addingTimeInterval(AgentBoard.recentWindow))
        #expect(agent.effective(at: now).state == .waiting)
    }

    @Test func archivedClosedAndHelperAgentsAreNotListed() {
        let listed = agents([paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000001", status: "closed"), paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000002", archived: true),
                             paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000003", helper: true), paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000004", status: "idle")])
        #expect(Set(listed.keys) == ["aaaaaaaa-0000-4000-8000-000000000004"])
    }

    @Test func nothingIsListedWhileTheDaemonIsDown() {
        var tracker = PaseoTracker()
        #expect(tracker.agents([paseoDecoded(paseoRecord(status: "running"))!], daemon: nil, cli: paseoCLI, now: now).isEmpty)
    }

    @Test func aRowCanBeSentToOnlyWhereTheCommandLineIs() throws {
        let agent = try #require(agents([paseoRecord(status: "idle")], cli: nil)[paseoAgentID])
        #expect(agent.input == nil)
        // Without the server's id the link can't be made, but the agent is still one to send to.
        var unnamed = daemon
        unnamed.serverID = nil
        var tracker = PaseoTracker()
        #expect(try #require(agents([paseoRecord()], daemon: unnamed, tracker: &tracker)[paseoAgentID]).input == .paseo(agent: paseoAgentID, server: nil))
    }

    @Test func otherToolsKeepTheirOwnNames() throws {
        let codex = paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000001", provider: "codex", title: nil, session: "01a130c4-3953-7f71-bc99-b8a6d37a5338", model: "gpt-5.6")
        let copilot = paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000002", provider: "copilot", model: nil)
        let listed = agents([codex, copilot])
        #expect(listed["aaaaaaaa-0000-4000-8000-000000000001"]?.tool == "codex" && listed["aaaaaaaa-0000-4000-8000-000000000001"]?.title == nil)
        #expect(listed["aaaaaaaa-0000-4000-8000-000000000002"]?.tool == "Copilot" && listed["aaaaaaaa-0000-4000-8000-000000000002"]?.model == nil)
    }
}

@MainActor
struct PaseoDedupeTests {
    private let now = paseoStart.addingTimeInterval(60)

    private func working(session: String?, tool: String = "claude", host: String? = nil) -> AgentBoard.Agent {
        AgentBoard.Agent(state: .working, since: paseoStart, tool: tool, session: session, host: host)
    }

    @Test func aHookRowForASessionPaseoRunsIsDroppedFromTheListAndTheCount() {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["h1": working(session: paseoSessionID.uppercased()), "h2": working(session: "someone-else-000")], now: now)
        board.replace(source: Paseo.source, with: [paseoAgentID: working(session: paseoSessionID, host: "Paseo")], now: now)
        #expect(board.entries(now: now).map(\.key).sorted() == ["hooks:claude|h2", "paseo|\(paseoAgentID)"])
        #expect(board.counts.working == 2)
        // Paseo's row going away brings the hook's back.
        board.clear(source: Paseo.source)
        #expect(board.entries(now: now).map(\.key).sorted() == ["hooks:claude|h1", "hooks:claude|h2"] && board.counts.working == 2)
    }

    private func paseoRow(_ state: AgentBoard.State, finished: Bool = false) -> AgentBoard.Agent {
        AgentBoard.Agent(state: state, expiresAt: state == .working ? nil : paseoStart.addingTimeInterval(AgentBoard.recentWindow), since: paseoStart, finished: finished,
                         tool: "claude", session: paseoSessionID, host: "Paseo")
    }

    @Test func anIdleOrFinishedPaseoRowDoesNotHideTheSameSessionWorkingInATerminal() {
        // `claude --resume <id>` keeps the session id: the terminal's hook row is working while Paseo's row is only a hand left behind.
        for paseo in [paseoRow(.idle), paseoRow(.waiting, finished: true)] {
            let board = AgentBoard()
            board.replace(source: "hooks:claude", with: ["h1": working(session: paseoSessionID)], now: now)
            board.replace(source: Paseo.source, with: [paseoAgentID: paseo], now: now)
            #expect(Set(board.entries(now: now).map(\.key)) == ["hooks:claude|h1", "paseo|\(paseoAgentID)"])
            #expect(board.counts.working == 1)
        }
    }

    @Test func aHookRowThatIsNotWorkingIsAlwaysDroppedForPaseosRowOfTheSession() {
        for paseo in [paseoRow(.idle), paseoRow(.working), paseoRow(.waiting), paseoRow(.waiting, finished: true)] {
            let board = AgentBoard()
            let idle = AgentBoard.Agent(state: .idle, expiresAt: paseoStart.addingTimeInterval(AgentBoard.recentWindow), since: paseoStart, tool: "claude", session: paseoSessionID)
            board.replace(source: "hooks:claude", with: ["h1": idle], now: now)
            board.replace(source: Paseo.source, with: [paseoAgentID: paseo], now: now)
            #expect(board.entries(now: now).map(\.key) == ["paseo|\(paseoAgentID)"])
        }
        // A row working or asking in Paseo takes the hook's working row too.
        for paseo in [paseoRow(.working), paseoRow(.waiting)] {
            let board = AgentBoard()
            board.replace(source: "hooks:claude", with: ["h1": working(session: paseoSessionID)], now: now)
            board.replace(source: Paseo.source, with: [paseoAgentID: paseo], now: now)
            #expect(board.entries(now: now).map(\.key) == ["paseo|\(paseoAgentID)"])
        }
    }

    @Test func aRowWithNoSessionIsNeverTakenForPaseosAndNeitherIsPaseoOfAnother() {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["h1": working(session: nil)], now: now)
        board.replace(source: "herdr:/tmp/s", with: ["p1": working(session: nil)], now: now)
        board.replace(source: Paseo.source, with: [paseoAgentID: working(session: nil)], now: now)
        #expect(board.entries(now: now).count == 3 && board.counts.working == 3)
    }
}

struct PaseoSendTests {
    @Test func aMessageGoesThroughTheCommandLineAsAnOptionValueAndNeverAShell() {
        let clis = TerminalCLIs(paseo: paseoCLI)
        #expect(AgentSend.steps(.paseo(agent: paseoAgentID, server: "srv"), text: "run the tests", submit: true, clis: clis)
                == [Paseo.run(paseoCLI, ["send", paseoAgentID, "--no-wait", "--prompt=run the tests"])])
        // A text that starts with a dash or holds shell syntax is still one argument.
        for text in ["-rf /", "--help", "$(touch x); `id` \"q\" 'q' \\n", "a=b"] {
            #expect(AgentSend.steps(.paseo(agent: paseoAgentID, server: nil), text: text, submit: true, clis: clis) == [Paseo.run(paseoCLI, ["send", paseoAgentID, "--no-wait", "--prompt=" + text])])
        }
    }

    @Test func nothingIsSentWithoutTheCommandLineOrToAnIdThatCouldBeAnOption() {
        #expect(AgentSend.steps(.paseo(agent: paseoAgentID, server: nil), text: "hi", submit: true, clis: TerminalCLIs()) == nil)
        #expect(AgentSend.steps(.paseo(agent: "--help", server: nil), text: "hi", submit: true, clis: TerminalCLIs(paseo: paseoCLI)) == nil)
        #expect(AgentSend.steps(.paseo(agent: "a b", server: nil), text: "hi", submit: true, clis: TerminalCLIs(paseo: paseoCLI)) == nil)
    }

    @Test func paseoSendsAMessageNeverHalfOfOne() {
        // Dropped files would be typed without Return; its command line has no such call.
        #expect(AgentSend.steps(.paseo(agent: paseoAgentID, server: nil), text: "/tmp/a.png ", submit: false, clis: TerminalCLIs(paseo: paseoCLI)) == nil)
        #expect(!AgentInput.paseo(agent: paseoAgentID, server: nil).takesFiles && AgentInput.muxy("1").takesFiles)
    }

    @Test func theLiveToolsIncludeThePaseoCommandLineWhereItIs() {
        #expect(TerminalCLIs.live.paseo == Paseo.cli())
    }
}

struct PaseoFocusTests {
    @Test func aClickGoesToTheAgentInTheAppOrToTheAppAlone() {
        let withServer = row(server: "srv_abc123")
        #expect(AgentFocus.plan(for: withServer, clis: TerminalCLIs(paseo: paseoCLI)) == .terminal(
            [.run(URL(fileURLWithPath: "/usr/bin/open"), ["-b", "sh.paseo.desktop", "paseo://h/srv_abc123/agent/\(paseoAgentID)"])], app: "sh.paseo.desktop"))
        #expect(AgentFocus.plan(for: row(server: nil), clis: TerminalCLIs(paseo: paseoCLI)) == .app("sh.paseo.desktop"))
        // A row with no command line has no input, but the app can still be gone to.
        #expect(AgentFocus.plan(for: row(server: "srv_abc123", input: false), clis: TerminalCLIs()) == .app("sh.paseo.desktop"))
        #expect(AgentFocus.bundleID(of: .paseo(agent: paseoAgentID, server: nil)) == "sh.paseo.desktop")
    }

    private func row(server: String?, input: Bool = true) -> AgentRow {
        let agent = AgentBoard.Agent(state: .idle, since: paseoStart, tool: "claude", app: Paseo.bundleID, cwd: "/Users/me/work/api",
                                     input: input ? .paseo(agent: paseoAgentID, server: server) : nil, host: "Paseo")
        return AgentRow(AgentBoard.Entry(source: Paseo.source, id: paseoAgentID, agent: agent), transcript: nil)
    }
}

struct PaseoRowTests {
    private func row(_ state: AgentBoard.State, finished: Bool = false, input: AgentInput? = .paseo(agent: paseoAgentID, server: "srv"), title: String? = "Fix the build",
                     model: String? = "claude-opus-5-5", transcript: AgentTranscript? = nil) -> AgentRow {
        let agent = AgentBoard.Agent(state: state, since: paseoStart, finished: finished, tool: "claude", app: Paseo.bundleID, cwd: "/Users/me/work/api", input: input,
                                     title: title, model: model, host: "Paseo")
        return AgentRow(AgentBoard.Entry(source: Paseo.source, id: paseoAgentID, agent: agent.effective(at: paseoStart)), transcript: transcript)
    }

    @Test func aRowTakesAMessageBetweenTurnsAndNotWhileItWorksOrAsks() {
        for state in [AgentBoard.State.idle] { #expect(row(state).acceptsInput && row(state).inputBlock == nil) }
        #expect(row(.waiting, finished: true).acceptsInput)
        let working = row(.working)
        #expect(!working.acceptsInput && working.inputBlock == .paseoBusy && working.offersInput)
        let asking = row(.waiting)
        #expect(!asking.acceptsInput && asking.inputBlock == .prompt)
    }

    @Test func aRowWithoutTheCommandLineSaysSo() {
        let row = row(.idle, input: nil)
        #expect(!row.acceptsInput && row.inputBlock == .paseoNoCLI)
        #expect(AgentRow.InputBlock.paseoNoCLI.message == String(localized: "Paseo's command line wasn't found, so Nunsseop can't send to this agent"))
        #expect(AgentRow.InputBlock.paseoBusy.message == String(localized: "Paseo would interrupt its turn: message it once it is done"))
    }

    @Test func aRowTakesNoDroppedFiles() {
        #expect(!row(.idle).takesDrops && row(.idle).acceptsInput)
        let muxy = AgentRow(AgentBoard.Entry(source: "hooks:claude", id: "a", agent: AgentBoard.Agent(state: .idle, input: .muxy("1"))), transcript: nil, inputVerified: true)
        #expect(muxy.takesDrops)
    }

    @Test func theTitleAndModelComeFromPaseoAndThePlaceItRunsIsNamed() {
        let plain = row(.idle)
        #expect(plain.title == "Fix the build" && plain.model == "claude-opus-5-5" && plain.host == "Paseo")
        #expect(plain.details == [String(localized: "Idle"), "api", "Claude Code", "Paseo", AgentTranscript.modelLabel("claude-opus-5-5")])
        // The transcript's model is the exact one; Paseo's title is the session's name over the transcript's.
        let withTranscript = row(.working, transcript: AgentTranscript(model: "claude-sonnet-5-5", name: "Another name"))
        #expect(withTranscript.title == "Fix the build" && withTranscript.model == "claude-sonnet-5-5")
        let unnamed = row(.working, title: nil, transcript: AgentTranscript(name: "From the transcript"))
        #expect(unnamed.title == "From the transcript")
        #expect(row(.working, title: nil).title == "api")
    }
}

@MainActor
struct PaseoModelTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [[AgentStep]] = []
        var passes = true
        var recorded: [[AgentStep]] { lock.withLock { plans } }
        var sender: AgentSender {
            AgentSender { [self] steps in
                lock.withLock { plans.append(steps) }
                return passes ? .sent : .failed
            }
        }
    }

    private func make(_ recorder: Recorder, agents: [String: AgentBoard.Agent], recent: [RecentConversation] = [], tool: URL? = paseoCLI) -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: Paseo.source, with: agents, now: paseoStart)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [], sender: recorder.sender,
                                   clis: { TerminalCLIs(paseo: tool) })
        model.fixedRecent = recent
        model.refresh(now: paseoStart)
        return model
    }

    private func agent(_ state: AgentBoard.State, finished: Bool = false) -> AgentBoard.Agent {
        AgentBoard.Agent(state: state, since: paseoStart, finished: finished, tool: "claude", app: Paseo.bundleID, cwd: "/Users/me/work/api",
                         input: .paseo(agent: paseoAgentID, server: "srv_abc123"), title: "Fix the build", host: "Paseo")
    }

    private func row(_ model: AgentsTabModel) throws -> AgentRow { try #require(model.rows.first) }

    @Test func aMessageToAnIdleAgentRunsTheCommandLineOffTheMainThread() async throws {
        let recorder = Recorder()
        let model = make(recorder, agents: [paseoAgentID: agent(.idle)])
        #expect(try row(model).acceptsInput)
        #expect(model.send(message: "  run the tests\n", to: try row(model)))
        await eventually { !recorder.recorded.isEmpty }
        #expect(recorder.recorded == [[Paseo.run(paseoCLI, ["send", paseoAgentID, "--no-wait", "--prompt=run the tests"])]])
    }

    @Test func nothingIsSentToAnAgentThatWorksOrAsks() async throws {
        for state in [AgentBoard.State.working, .waiting] {
            let recorder = Recorder()
            let model = make(recorder, agents: [paseoAgentID: agent(state)])
            #expect(!model.send(message: "hello", to: try row(model)))
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(recorder.recorded.isEmpty)
        }
    }

    @Test func droppedFilesAreNotTakenByAnAgent() async throws {
        let recorder = Recorder()
        let model = make(recorder, agents: [paseoAgentID: agent(.idle)])
        #expect(!model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: try row(model)))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.recorded.isEmpty)
    }

    @Test func aMessageWithoutTheCommandLineLeavesANote() async throws {
        let recorder = Recorder()
        let board = AgentBoard()
        var noInput = agent(.idle)
        noInput.input = nil
        board.replace(source: Paseo.source, with: [paseoAgentID: noInput], now: paseoStart)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [], sender: recorder.sender, clis: { TerminalCLIs() })
        model.fixedRecent = []
        model.refresh(now: paseoStart)
        #expect(try row(model).inputBlock == .paseoNoCLI && !model.send(message: "hi", to: try row(model)))
    }

    @Test func aRecentAgentComesBackThroughImportWhenItWasArchivedAndOnlyOpensWhenItWasNot() async throws {
        let archived = PaseoResume(agent: paseoAgentID, provider: "claude", session: paseoSessionID, cwd: "/Users/me/work/api", archived: true, server: "srv_abc123")
        let recorder = Recorder()
        var conversation = RecentConversation(kind: .claude, session: paseoSessionID, cwd: "/Users/me/work/api", modified: paseoStart, name: "Fix the build")
        conversation.paseo = archived
        let model = make(recorder, agents: [:], recent: [conversation])
        model.resume(conversation, now: paseoStart)
        await eventually { !recorder.recorded.isEmpty }
        #expect(recorder.recorded == [[Paseo.run(paseoCLI, ["import", paseoSessionID, "--provider", "claude", "--cwd=/Users/me/work/api"]),
                                       .run(URL(fileURLWithPath: "/usr/bin/open"), ["-b", "sh.paseo.desktop", "paseo://h/srv_abc123/agent/\(paseoAgentID)"])]])
        // A second click within the window does not start it twice.
        model.resume(conversation, now: paseoStart.addingTimeInterval(1))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.recorded.count == 1)

        var open = conversation
        open.paseo = PaseoResume(agent: paseoAgentID, provider: "claude", session: paseoSessionID, cwd: "/Users/me/work/api", archived: false, server: nil)
        let second = Recorder()
        let other = make(second, agents: [:], recent: [open])
        other.resume(open, now: paseoStart)
        await eventually { !second.recorded.isEmpty }
        #expect(second.recorded == [[.run(URL(fileURLWithPath: "/usr/bin/open"), ["-b", "sh.paseo.desktop"])]])
    }

    @Test func anArchivedAgentWithTheDaemonDownOnlyStartsTheAppAndLeavesANoteToTryAgain() async throws {
        var conversation = RecentConversation(kind: .claude, session: paseoSessionID, cwd: "/Users/me/work/api", modified: paseoStart)
        conversation.paseo = PaseoResume(agent: paseoAgentID, provider: "claude", session: paseoSessionID, cwd: "/Users/me/work/api", archived: true, server: nil, daemonUp: false)
        let recorder = Recorder()
        let model = make(recorder, agents: [:], recent: [conversation])
        model.resume(conversation, now: paseoStart)
        await eventually { !recorder.recorded.isEmpty && model.resumeNote != nil }
        #expect(recorder.recorded == [[.run(URL(fileURLWithPath: "/usr/bin/open"), ["-b", "sh.paseo.desktop"])]])
        #expect(model.resumeNote != nil)
        // The click is for again at once, not after the window that keeps a double click from starting it twice.
        model.resume(conversation, now: paseoStart.addingTimeInterval(1))
        await eventually { recorder.recorded.count == 2 }
        #expect(recorder.recorded.count == 2)
    }

    @Test func aFailedResumeLeavesANoteAndCanBeTriedAgain() async throws {
        let recorder = Recorder()
        recorder.passes = false
        var conversation = RecentConversation(kind: .claude, session: paseoSessionID, cwd: "/Users/me/work/api", modified: paseoStart)
        conversation.paseo = PaseoResume(agent: paseoAgentID, provider: "claude", session: paseoSessionID, cwd: "/Users/me/work/api", archived: false, server: nil)
        let model = make(recorder, agents: [:], recent: [conversation])
        model.resume(conversation, now: paseoStart)
        // Not compared with the sentence: any model hears the "not allowed" notices other tests post to the whole process.
        await eventually { model.resumeNote != nil }
        #expect(model.resumeNote != nil)
        model.resume(conversation, now: paseoStart.addingTimeInterval(1))
        await eventually { recorder.recorded.count == 2 }
        #expect(recorder.recorded.count == 2)
        // An archived agent can't come back without the command line: a note, and no call.
        var archived = conversation
        archived.paseo = PaseoResume(agent: paseoAgentID, provider: "claude", session: paseoSessionID, cwd: "/Users/me/work/api", archived: true, server: nil)
        let none = Recorder()
        let bare = make(none, agents: [:], recent: [archived], tool: nil)
        bare.resume(archived, now: paseoStart)
        #expect(bare.resumeNote != nil && none.recorded.isEmpty)
    }
}

struct PaseoRecentsTests {
    private let now = paseoStart.addingTimeInterval(3_600)
    private let work = FileManager.default.temporaryDirectory.path

    private func records(_ objects: [[String: Any]]) -> [PaseoRecord] { objects.compactMap(paseoDecoded) }

    @Test func closedAndArchivedAgentsWithASessionAreOfferedNewestFirst() {
        let found = PaseoRecents.list(
            records([paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000001", cwd: work, status: "closed", updated: paseoStart.addingTimeInterval(-100), title: "Old"),
                     paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000002", cwd: work, status: "idle", updated: paseoStart, title: "New", archived: true)]),
            excluding: [], server: "srv", now: now, scratch: [])
        #expect(found.map(\.title) == ["New", "Old"])
        #expect(found[0].paseo == PaseoResume(agent: "aaaaaaaa-0000-4000-8000-000000000002", provider: "claude", session: paseoSessionID, cwd: work, archived: true, server: "srv"))
        #expect(found[1].paseo?.archived == false && found[0].id == "paseo|aaaaaaaa-0000-4000-8000-000000000002")
        #expect(Array(found[0].details(now: now).prefix(3)) == [(work as NSString).lastPathComponent, "Claude Code", "Paseo"])
    }

    @Test func anOpenAgentASessionOpenElsewhereAHelperAndAChildAreLeftOut() {
        let objects = [paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000001", cwd: work, session: "1b2c3d4e-0000-4000-8000-0000000000a1"),
                       paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000002", cwd: work, session: "1b2c3d4e-0000-4000-8000-0000000000a2"),
                       paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000003", cwd: work, helper: true, session: "1b2c3d4e-0000-4000-8000-0000000000a3"),
                       paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000004", cwd: work, session: "1b2c3d4e-0000-4000-8000-0000000000a4", parent: "aaaaaaaa-0000-4000-8000-000000000001"),
                       paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000005", cwd: work, session: nil),
                       paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000006", cwd: "/nonexistent/folder", session: "1b2c3d4e-0000-4000-8000-0000000000a6"),
                       paseoRecord(id: "aaaaaaaa-0000-4000-8000-000000000007", cwd: work, session: "1b2c3d4e-0000-4000-8000-0000000000a7")]
        let found = PaseoRecents.list(records(objects), excluding: ["aaaaaaaa-0000-4000-8000-000000000001", "1b2c3d4e-0000-4000-8000-0000000000a7"], server: nil, now: now, scratch: [])
        #expect(found.compactMap { $0.paseo?.agent } == ["aaaaaaaa-0000-4000-8000-000000000002"])
    }

    @Test func aScratchFolderAndAnOldAgentAreLeftOutAndTheListIsCapped() {
        #expect(PaseoRecents.list(records([paseoRecord(cwd: work)]), excluding: [], server: nil, now: now) .isEmpty)
        #expect(PaseoRecents.list(records([paseoRecord(cwd: work, updated: paseoStart.addingTimeInterval(-RecentConversations.window - 60))]), excluding: [], server: nil,
                                  now: paseoStart, scratch: []).isEmpty)
        let many = (0..<9).map { paseoRecord(id: "aaaaaaaa-0000-4000-8000-00000000000\($0)", cwd: work, session: "1b2c3d4e-0000-4000-8000-00000000000\($0)") }
        #expect(PaseoRecents.list(records(many), excluding: [], server: nil, now: now, scratch: []).count == RecentConversations.limit)
    }

    @Test func theToolsAndPaseoAreMergedWithPaseoWinningASharedSession() {
        let tool = RecentConversation(kind: .claude, session: paseoSessionID.uppercased(), cwd: work, modified: paseoStart.addingTimeInterval(10), name: "File")
        let other = RecentConversation(kind: .codex, session: "01a130c4-3953-7f71-bc99-b8a6d37a5338", cwd: work, modified: paseoStart.addingTimeInterval(-10))
        let mine = PaseoRecents.list(records([paseoRecord(cwd: work)]), excluding: [], server: nil, now: now, scratch: [])
        let merged = PaseoRecents.merged([tool, other], mine)
        #expect(merged.map(\.id) == ["paseo|\(paseoAgentID)", other.id])
        #expect(PaseoRecents.merged([tool, other], []) == [tool, other])
    }

    @Test func theStepsToBringAnAgentBackAreImportThenTheAppOrTheAppAlone() {
        let archived = PaseoResume(agent: paseoAgentID, provider: "codex", session: "01a130c4-3953-7f71-bc99-b8a6d37a5338", cwd: "/Users/me/work/api", archived: true, server: "srv")
        #expect(archived.steps(cli: paseoCLI) == [Paseo.run(paseoCLI, ["import", "01a130c4-3953-7f71-bc99-b8a6d37a5338", "--provider", "codex", "--cwd=/Users/me/work/api"]),
                                              Paseo.openStep(server: "srv", agent: paseoAgentID)])
        #expect(archived.steps(cli: nil) == nil)
        var open = archived
        open = PaseoResume(agent: paseoAgentID, provider: "codex", session: archived.session, cwd: archived.cwd, archived: false, server: "srv")
        #expect(open.steps(cli: nil) == [Paseo.openStep(server: "srv", agent: paseoAgentID)])
        // `paseo import` never starts a daemon: with it down an archived agent only gets the app, which does, and no call that would fail.
        var down = archived
        down.daemonUp = false
        #expect(down.needsDaemon && down.steps(cli: paseoCLI) == [Paseo.openStep(server: nil, agent: paseoAgentID)] && down.steps(cli: nil) == down.steps(cli: paseoCLI))
        // An agent that was not archived needs no import, and the app takes it from the link (the server's id is known from its file).
        var plain = open
        plain.daemonUp = false
        #expect(!plain.needsDaemon && plain.steps(cli: nil) == [Paseo.openStep(server: "srv", agent: paseoAgentID)])
    }

    @Test func theListSaysWhetherTheDaemonWasUp() {
        let found = PaseoRecents.list(records([paseoRecord(cwd: work, archived: true)]), excluding: [], server: "srv", daemonUp: false, now: now, scratch: [])
        #expect(found.first?.paseo?.daemonUp == false && found.first?.paseo?.needsDaemon == true)
        #expect(PaseoRecents.list(records([paseoRecord(cwd: work)]), excluding: [], server: nil, now: now, scratch: []).first?.paseo?.daemonUp == true)
    }
}
