import Foundation
import Network
import Testing
@testable import Nunsseop

// The daemon's WebSocket, the cards made from its permission requests, and the watcher that joins them to the board. Messages are shaped
// like the schemas of Paseo's protocol/src/messages.ts. The sockets are made-up ones, except in the last test, which talks to a stand-in
// daemon on the loopback through the real `URLSession` socket.

private func object(_ text: String) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
}

private func json(_ value: [String: Any]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

private func session(_ message: [String: Any]) -> String { json(["type": "session", "message": message]) }

private func serverInfo(_ id: String = "srv_abc123") -> String {
    session(["type": "status", "payload": ["status": "server_info", "serverId": id, "hostname": "mac", "version": "0.9.1", "protocolVersion": 1,
                                           "features": ["ownedSubscriptions": true]]])
}

private func permission(_ id: String, name: String = "Bash", kind: String = "tool", input: [String: Any]? = ["command": "ls -la"]) -> [String: Any] {
    var value: [String: Any] = ["id": id, "provider": "claude", "name": name, "kind": kind, "title": "Run ls", "description": "List files"]
    if let input { value["input"] = input }
    return value
}

private func requested(_ agent: String, _ request: [String: Any]) -> String {
    session(["type": "agent_permission_request", "payload": ["agentId": agent, "request": request]])
}

private func resolved(_ agent: String, _ request: String) -> String {
    session(["type": "agent_permission_resolved", "payload": ["agentId": agent, "requestId": request, "resolution": ["behavior": "allow"]]])
}

private func attention(_ agent: String, _ reason: String) -> String {
    session(["type": "agent_attention_required", "payload": ["agentId": agent, "reason": reason, "timestamp": "2026-10-13T08:00:00.000Z", "shouldNotify": false]])
}

private func listing(_ request: String, _ agents: [String: [[String: Any]]]) -> String {
    let entries = agents.map { agent, pending -> [String: Any] in
        ["agent": ["id": agent, "provider": "claude", "cwd": "/Users/me/work/api", "status": "running", "pendingPermissions": pending], "project": ["projectKey": "k"]]
    }
    return session(["type": "fetch_agents_response", "payload": ["requestId": request, "entries": entries, "pageInfo": ["nextCursor": NSNull(), "prevCursor": NSNull(), "hasMore": false]]])
}

private let agentA = "6f1b2c3d-0000-4000-8000-00000000000a"
private let agentB = "6f1b2c3d-0000-4000-8000-00000000000b"

struct PaseoWireTests {
    @Test func theHelloIsTheOneTheProtocolDescribes() {
        let hello = object(PaseoWire.hello(clientID: "nunsseop_ab12"))
        #expect(hello["type"] as? String == "hello" && hello["clientId"] as? String == "nunsseop_ab12" && hello["clientType"] as? String == "cli")
        #expect(hello["protocolVersion"] as? Int == 1 && hello["appVersion"] == nil && hello["auth"] == nil)
        let capabilities = hello["capabilities"] as? [String: Bool]
        #expect(capabilities == ["hello_rejection": true, "owned_subscriptions": true, "explicit_event_subscriptions": true, "selective_agent_timeline": true,
                                 "all_providers": true])
    }

    @Test func theSubscriptionAsksForTheThreeEventsAndNothingMore() {
        let request = object(PaseoWire.subscribe(request: "nunsseop-1"))
        let message = request["message"] as? [String: Any]
        #expect(request["type"] as? String == "session" && message?["type"] as? String == "session.events.set_subscription.request")
        #expect(message?["requestId"] as? String == "nunsseop-1" && message?["events"] as? [String] == ["agent_permission_request", "agent_permission_resolved", "agent_attention_required"])
        #expect(message?["notifications"] == nil)
    }

    @Test func theListingAsksForRunningAgentsMostUrgentFirst() {
        let message = object(PaseoWire.running(request: "nunsseop-list-1"))["message"] as? [String: Any]
        #expect(message?["type"] as? String == "fetch_agents_request" && message?["requestId"] as? String == "nunsseop-list-1")
        #expect((message?["filter"] as? [String: Any])?["statuses"] as? [String] == ["running"] && message?["subscribe"] == nil)
        let sort = (message?["sort"] as? [[String: String]])?.first
        #expect(sort == ["key": "status_priority", "direction": "asc"] && (message?["page"] as? [String: Int])?["limit"] == 100)
    }

    @Test func anAnswerNamesTheAgentTheRequestAndTheBehaviorAlone() {
        for allow in [true, false] {
            let message = object(PaseoWire.answer(agent: agentA, request: "req-1", allow: allow))["message"] as? [String: Any]
            #expect(message?["type"] as? String == "agent_permission_response" && message?["agentId"] as? String == agentA && message?["requestId"] as? String == "req-1")
            #expect(message?["response"] as? [String: String] == ["behavior": allow ? "allow" : "deny"])
        }
        #expect(PaseoWire.ping == #"{"type":"ping"}"#)
    }

    @Test func theMessagesTheDaemonSendsAreRead() {
        #expect(PaseoWire.decode(serverInfo("srv_x")) == .serverInfo("srv_x"))
        #expect(PaseoWire.decode(#"{"type":"pong"}"#) == .pong)
        #expect(PaseoWire.decode(#"{"type":"hello.rejected","reason":"password_required","accepts":["password"]}"#) == .rejected("password_required"))
        let request = PaseoWire.decode(requested(agentA, permission("r1", input: ["command": "ls", "n": 2])))
        guard case .requested(let agent, let found) = request else { Issue.record("not a request"); return }
        #expect(agent == agentA && found.id == "r1" && found.name == "Bash" && found.kind == "tool" && found.title == "Run ls" && found.summary == "List files")
        #expect(object(String(decoding: found.input ?? Data(), as: UTF8.self))["command"] as? String == "ls")
        #expect(PaseoWire.decode(resolved(agentA, "r1")) == .resolved(agent: agentA, request: "r1"))
        #expect(PaseoWire.decode(attention(agentA, "finished")) == .attention(agent: agentA, reason: "finished"))
    }

    @Test func aListingKeepsOnlyTheAgentsWithSomethingWaiting() {
        let message = listing("nunsseop-list-3", [agentA: [permission("r1")], agentB: []])
        guard case .listing(let request, let agents) = PaseoWire.decode(message) else { Issue.record("not a listing"); return }
        #expect(request == "nunsseop-list-3" && Set(agents.keys) == [agentA] && agents[agentA]?.map(\.id) == ["r1"])
    }

    @Test func whatIsNotUnderstoodIsNotAnError() {
        for text in ["", "nonsense", "[]", #"{"type":"session"}"#, #"{"type":"session","message":{"type":"agent_stream","payload":{}}}"#, #"{"type":"other"}"#,
                     session(["type": "status", "payload": ["status": "daemon_config_changed"]]),
                     session(["type": "agent_permission_request", "payload": ["agentId": agentA, "request": ["id": "", "name": "Bash"]]]),
                     session(["type": "status", "payload": ["status": "server_info", "serverId": ""]])] {
            #expect(PaseoWire.decode(text) == .other, Comment(rawValue: text))
        }
    }
}

/// A socket the test drives: it records what is sent and gives back what is pushed.
final class FakePaseoSocket: PaseoSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator
    private(set) var closed = false

    init() {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.continuation = continuation
        iterator = stream.makeAsyncIterator()
    }

    var sent: [String] { lock.withLock { stored } }
    /// The sent messages of one type (`type` of the envelope's message, or of the message itself).
    func sent(_ type: String) -> [[String: Any]] {
        sent.map(object).filter { ($0["message"] as? [String: Any])?["type"] as? String == type || $0["type"] as? String == type }
    }
    func push(_ text: String) { continuation.yield(text) }
    /// The connection breaks.
    func drop() { continuation.finish(throwing: URLError(.networkConnectionLost)) }

    func send(_ text: String) async throws {
        try lock.withLock {
            if closed { throw URLError(.networkConnectionLost) }
            stored.append(text)
        }
    }

    func receive() async throws -> String {
        guard let text = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return text
    }

    func close() {
        lock.withLock { closed = true }
        continuation.finish()
    }
}

/// The sockets a client asks for, in the order made.
final class PaseoSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakePaseoSocket] = []
    private var addresses: [URL] = []

    func make(_ url: URL) -> PaseoSocket {
        lock.withLock {
            let socket = FakePaseoSocket()
            made.append(socket)
            addresses.append(url)
            return socket
        }
    }
    var all: [FakePaseoSocket] { lock.withLock { made } }
    var urls: [URL] { lock.withLock { addresses } }
}

let quickTiming = PaseoClient.Timing(idle: 0.05, refused: 5, retry: [0.05], ping: 5, silence: 100, relist: 100)

@MainActor
struct PaseoClientTests {
    private let url = URL(string: "ws://127.0.0.1:6767/ws")!

    private final class Seen {
        var added: [(agent: String, id: String)] = []
        var removed: [(agent: String, id: String)] = []
        var attention: [(agent: String, reason: String)] = []
        var states: [PaseoClient.State] = []
    }

    private func make(_ sockets: PaseoSockets, timing: PaseoClient.Timing = quickTiming, endpoint: URL? = URL(string: "ws://127.0.0.1:6767/ws"),
                      clock: @escaping () -> Date = { .now }) -> (PaseoClient, Seen) {
        let client = PaseoClient(endpoint: { endpoint }, clientID: "nunsseop_test", timing: timing, clock: clock, socket: { sockets.make($0) })
        let seen = Seen()
        client.onAdded = { seen.added.append(($0, $1.id)) }
        client.onRemoved = { seen.removed.append(($0, $1)) }
        client.onAttention = { seen.attention.append(($0, $1)) }
        client.onState = { seen.states.append($0) }
        return (client, seen)
    }

    /// Connects to the first socket and answers its hello.
    private func connect(_ client: PaseoClient, _ sockets: PaseoSockets) async -> FakePaseoSocket? {
        client.start()
        await eventually { !sockets.all.isEmpty && !sockets.all[0].sent.isEmpty }
        guard let socket = sockets.all.first else { return nil }
        socket.push(serverInfo())
        await eventually { client.state == .ready && !socket.sent("fetch_agents_request").isEmpty }
        return socket
    }

    @Test func itSaysHelloFirstAndThenAsksForTheEventsAndTheRunningAgents() async throws {
        let sockets = PaseoSockets()
        let (client, _) = make(sockets)
        client.start()
        await eventually { !sockets.all.isEmpty && !sockets.all[0].sent.isEmpty }
        let socket = try #require(sockets.all.first)
        #expect(sockets.urls == [url] && client.state == .connecting)
        let hello = object(try #require(socket.sent.first))
        #expect(hello["type"] as? String == "hello" && hello["clientId"] as? String == "nunsseop_test")
        // Nothing else is sent before the daemon has answered.
        #expect(socket.sent.count == 1)
        socket.push(serverInfo())
        await eventually { client.state == .ready && socket.sent.count >= 3 }
        #expect(socket.sent("session.events.set_subscription.request").count == 1 && socket.sent("fetch_agents_request").count == 1)
        client.stop()
    }

    @Test func requestsComeAndGoAsTheDaemonSaysAndAreNotCountedTwice() async throws {
        let sockets = PaseoSockets()
        let (client, seen) = make(sockets)
        let socket = try #require(await connect(client, sockets))
        socket.push(requested(agentA, permission("r1")))
        socket.push(requested(agentA, permission("r1")))
        socket.push(requested(agentB, permission("r2", kind: "plan")))
        await eventually { seen.added.count >= 2 }
        #expect(seen.added.map(\.id) == ["r1", "r2"] && client.pendingAgents == [agentA, agentB] && client.pendingRequests.count == 2)
        socket.push(resolved(agentA, "r1"))
        socket.push(resolved(agentA, "r1"))
        await eventually { !seen.removed.isEmpty }
        #expect(seen.removed.map(\.id) == ["r1"] && client.pendingAgents == [agentB])
        socket.push(attention(agentB, "finished"))
        await eventually { !seen.attention.isEmpty }
        #expect(seen.attention.map(\.reason) == ["finished"] && seen.attention.map(\.agent) == [agentB])
        client.stop()
    }

    @Test func aListingBringsTheRequestsMadeBeforeItConnectedAndDropsTheOnesThatAreGone() async throws {
        var timing = quickTiming
        timing.ping = 0.05
        timing.relist = 0.1
        let sockets = PaseoSockets()
        let (client, seen) = make(sockets, timing: timing)
        let socket = try #require(await connect(client, sockets))
        socket.push(listing("nunsseop-list-1", [agentA: [permission("r1")]]))
        await eventually { seen.added.map(\.id) == ["r1"] }
        #expect(client.pendingAgents == [agentA])
        // The second listing is asked for on the timer. A request that comes after it was asked for belongs to the world it doesn't
        // know about: the answer, which leaves out r3, does not take it away, and it does take away r1, which was there before.
        await eventually { socket.sent("fetch_agents_request").count >= 2 }
        socket.push(requested(agentB, permission("r3")))
        await eventually { seen.added.map(\.id).contains("r3") }
        socket.push(listing("nunsseop-list-2", [:]))
        await eventually { seen.removed.map(\.id).contains("r1") }
        #expect(!seen.removed.map(\.id).contains("r3") && client.pendingRequests.map(\.permission.id) == ["r3"])
        client.stop()
    }

    @Test func aListingThatIsNotOursIsIgnored() async throws {
        let sockets = PaseoSockets()
        let (client, seen) = make(sockets)
        let socket = try #require(await connect(client, sockets))
        socket.push(listing("someone-else-1", [agentA: [permission("r1")]]))
        socket.push(requested(agentB, permission("r2")))
        await eventually { seen.added.count >= 1 }
        #expect(seen.added.map(\.id) == ["r2"])
        client.stop()
    }

    @Test func aLostConnectionForgetsWhatWaitedAndConnectsAgain() async throws {
        let sockets = PaseoSockets()
        let (client, seen) = make(sockets)
        let socket = try #require(await connect(client, sockets))
        socket.push(requested(agentA, permission("r1")))
        await eventually { !seen.added.isEmpty }
        socket.drop()
        await eventually { sockets.all.count >= 2 }
        #expect(seen.removed.map(\.id) == ["r1"] && client.pendingAgents.isEmpty)
        let second = sockets.all[1]
        await eventually { !second.sent.isEmpty }
        #expect(object(second.sent[0])["type"] as? String == "hello")
        second.push(serverInfo())
        await eventually { client.state == .ready }
        #expect(client.state == .ready)
        client.stop()
    }

    @Test func aPasswordTheDaemonAsksForIsNotTriedAgainAtOnce() async throws {
        let sockets = PaseoSockets()
        let (client, _) = make(sockets)
        client.start()
        await eventually { !sockets.all.isEmpty && !sockets.all[0].sent.isEmpty }
        sockets.all[0].push(#"{"type":"hello.rejected","reason":"password_required","accepts":["password"]}"#)
        await eventually { client.state == .refused }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.state == .refused && sockets.all.count == 1 && sockets.all[0].closed)
        client.stop()
    }

    @Test func anAnswerGoesOutOnlyOnAReadyConnection() async throws {
        let sockets = PaseoSockets()
        let (client, _) = make(sockets)
        #expect(!client.respond(agent: agentA, request: "r1", allow: true))
        let socket = try #require(await connect(client, sockets))
        #expect(client.respond(agent: agentA, request: "r1", allow: true) && client.respond(agent: agentB, request: "r2", allow: false))
        await eventually { socket.sent("agent_permission_response").count == 2 }
        let answers = socket.sent("agent_permission_response").compactMap { $0["message"] as? [String: Any] }
        #expect(answers.map { $0["requestId"] as? String } == ["r1", "r2"] && answers.map { ($0["response"] as? [String: String])?["behavior"] } == ["allow", "deny"])
        client.stop()
        #expect(!client.respond(agent: agentA, request: "r3", allow: true))
    }

    @Test func itPingsOnTheTimerAsTheDaemonsLeaseNeeds() async throws {
        var timing = quickTiming
        timing.ping = 0.05
        let sockets = PaseoSockets()
        let (client, _) = make(sockets, timing: timing)
        let socket = try #require(await connect(client, sockets))
        await eventually { socket.sent("ping").count >= 3 }
        #expect(socket.sent("ping").count >= 3 && socket.sent.contains(PaseoWire.ping))
        client.stop()
    }

    /// A clock the test moves by hand, so how long the daemon has been silent does not depend on how fast the machine is.
    private final class HandClock: @unchecked Sendable {
        private let lock = NSLock()
        private var moment = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var now: Date { lock.withLock { moment } }
        func advance(_ seconds: TimeInterval) { lock.withLock { moment = moment.addingTimeInterval(seconds) } }
    }

    @Test func aConnectionThatNeverAnswersIsTakenForDeadAndMadeAgain() async throws {
        var timing = quickTiming
        timing.ping = 0.02
        timing.silence = 20
        let clock = HandClock()
        let sockets = PaseoSockets()
        let (client, _) = make(sockets, timing: timing, clock: { clock.now })
        let first = try #require(await connect(client, sockets))
        await eventually { !first.sent("ping").isEmpty }
        #expect(!first.closed)
        // Longer than the daemon may be silent: closing ends the read, which ends the connection, and a new one follows.
        clock.advance(21)
        await eventually { first.closed && sockets.all.count >= 2 }
        #expect(first.closed && sockets.all.count >= 2)
        client.stop()
    }

    @Test func aConnectionThatKeepsAnsweringIsKeptHoweverLongItRuns() async throws {
        var timing = quickTiming
        timing.ping = 0.02
        timing.silence = 20
        let clock = HandClock()
        let sockets = PaseoSockets()
        let (client, _) = make(sockets, timing: timing, clock: { clock.now })
        let socket = try #require(await connect(client, sockets))
        // Each time the daemon answers a ping, twelve seconds go by: far more than the limit in all, never more than it between answers.
        for round in 1...6 {
            await eventually { socket.sent("ping").count >= round }
            clock.advance(12)
            socket.push(#"{"type":"pong"}"#)
            await eventually { client.lastPong == clock.now }
            #expect(client.lastPong == clock.now)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!socket.closed && sockets.all.count == 1 && client.state == .ready)
        client.stop()
    }

    @Test func withoutADaemonItWaitsAndMakesNoSocket() async throws {
        let sockets = PaseoSockets()
        let (client, seen) = make(sockets, endpoint: nil)
        client.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(client.state == .waiting && sockets.all.isEmpty && seen.states == [.waiting])
        client.stop()
        #expect(client.state == .stopped)
    }

    @Test func stoppingClosesTheSocketAndTakesTheRequestsAway() async throws {
        let sockets = PaseoSockets()
        let (client, seen) = make(sockets)
        let socket = try #require(await connect(client, sockets))
        socket.push(requested(agentA, permission("r1")))
        await eventually { !seen.added.isEmpty }
        client.stop()
        #expect(socket.closed && client.state == .stopped && seen.removed.map(\.id) == ["r1"] && client.pendingAgents.isEmpty)
        // No new connection follows.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(sockets.all.count == 1)
    }
}

struct PaseoPermissionTests {
    @Test func theDetailIsKeptAsTheFieldsThatSaySomething() throws {
        func detail(_ value: Any?) -> [String: Any]? { PaseoPermission.fields(of: value as? [String: Any]) }
        #expect(detail(["type": "shell", "command": "ls", "cwd": "/tmp", "output": NSNull(), "exitCode": NSNull()]) as? [String: String] == ["command": "ls", "cwd": "/tmp"])
        #expect(detail(["type": "unknown", "input": ["reason": "why"], "output": NSNull()]) as? [String: String] == ["reason": "why"])
        #expect(detail(["type": "unknown", "input": NSNull(), "output": NSNull()]) == nil && detail(["type": "unknown", "input": ["reason": NSNull()]]) == nil)
        #expect(detail(["type": "edit", "filePath": "/a", "unifiedDiff": ""]) as? [String: String] == ["filePath": "/a"] && detail(nil) == nil)
    }
}

@MainActor
struct PaseoApprovalTests {
    private struct Sent: Equatable {
        let agent: String
        let request: String
        let allow: Bool
    }

    @MainActor private final class Wiring {
        let board = PermissionBoard()
        let approvals: PaseoApprovals
        var sent: [Sent] = []
        var connected = true

        init(folders: [String: String] = [agentA: "/Users/me/work/api"], enabled: Bool = true) {
            approvals = PaseoApprovals(board: board)
            approvals.isEnabled = { enabled }
            approvals.folder = { folders[$0] ?? "" }
            approvals.send = { [unowned self] in
                guard connected else { return false }
                sent.append(Sent(agent: $0, request: $1, allow: $2))
                return true
            }
            board.onAnswer = { [unowned self] in _ = approvals.answer($0, $1) }
        }

        /// A request as the daemon sends it, whatever it carries.
        func addRaw(_ request: [String: Any], agent: String = agentA) {
            guard case .requested(_, let found) = PaseoWire.decode(requested(agent, request)) else { return }
            approvals.added(agent: agent, found)
        }

        func add(_ id: String = "r1", agent: String = agentA, name: String = "Bash", kind: String = "tool", input: [String: Any]? = ["command": "rm -rf build"]) {
            guard case .requested(_, let found) = PaseoWire.decode(requested(agent, permission(id, name: name, kind: kind, input: input))) else { return }
            approvals.added(agent: agent, found)
        }
    }

    @Test func aToolCallBecomesACardTaggedPaseoAndShownLikeAnyOther() throws {
        let wiring = Wiring()
        wiring.add()
        let prompt = try #require(wiring.board.current)
        #expect(wiring.board.prompts.count == 1 && prompt.tag == "Paseo" && prompt.grant == nil && !prompt.isCodex && prompt.asking == nil)
        #expect(prompt.title == String(localized: "Run a command") && prompt.detail.contains("rm -rf build") && prompt.folder == "api")
    }

    @Test func aToolTheCardDoesNotKnowShowsItsNameAndInput() throws {
        let wiring = Wiring()
        wiring.add(name: "mcp__github__create_issue", input: ["title": "Bug", "repo": "me/api"])
        let prompt = try #require(wiring.board.current)
        #expect(prompt.title.contains("create_issue") || prompt.toolLine.contains("create_issue"))
        #expect(prompt.scrollText.contains("Bug") && prompt.scrollText.contains("me/api"))
    }

    @Test func anAcpRequestWithoutInputIsShownByItsTitleAndDetail() throws {
        // An ACP provider (OpenCode, Pi, Copilot...) names the tool by its kind and says what it does in the title and the detail
        // (acp-agent.ts mapPermissionRequest); it sends no `input`.
        let wiring = Wiring()
        wiring.addRaw(["id": "r1", "provider": "opencode", "name": "execute", "kind": "tool", "title": "Run ls -la /tmp",
                       "detail": ["type": "shell", "command": "ls -la /tmp", "cwd": "/Users/me/work/api"],
                       "actions": [["id": "allow", "label": "Allow", "behavior": "allow"]]])
        let prompt = try #require(wiring.board.current)
        #expect(prompt.title == "Run ls -la /tmp" && prompt.tag == "Paseo")
        #expect(!prompt.detail.isEmpty && prompt.scrollText.contains("ls -la /tmp") && prompt.scrollText.contains("/Users/me/work/api"))
        // Without a detail the title alone says what is asked, in the card's title and its body.
        let titled = Wiring()
        titled.addRaw(["id": "r2", "provider": "pi", "name": "edit", "kind": "tool", "title": "Edit src/main.swift"])
        let second = try #require(titled.board.current)
        #expect(second.title == "Edit src/main.swift" && second.detail.contains("Edit src/main.swift"))
    }

    @Test func aCodexFileChangeShowsItsReasonAndAnEmptyOneStillSaysWhatItIs() throws {
        // Codex sends the title "Apply file changes", the optional reason as the description, and an `unknown` detail holding it.
        let wiring = Wiring()
        wiring.addRaw(["id": "r1", "provider": "codex", "name": "CodexFileChange", "kind": "tool", "title": "Apply file changes", "description": "needs to write outside the project",
                       "detail": ["type": "unknown", "input": ["reason": "needs to write outside the project"], "output": NSNull()]])
        let prompt = try #require(wiring.board.current)
        #expect(prompt.title == "Apply file changes" && prompt.detail.contains("needs to write outside the project"))
        #expect(!prompt.detail.contains("null") && !prompt.detail.contains("unknown"))
        let bare = Wiring()
        bare.addRaw(["id": "r2", "provider": "codex", "name": "CodexFileChange", "kind": "tool", "title": "Apply file changes",
                     "detail": ["type": "unknown", "input": ["reason": NSNull()], "output": NSNull()]])
        let empty = try #require(bare.board.current)
        #expect(empty.title == "Apply file changes" && !empty.detail.isEmpty)
    }

    @Test func aRequestThatSaysNothingOfWhatItAsksGetsNoCard() {
        let wiring = Wiring()
        wiring.addRaw(["id": "r1", "provider": "x", "name": "execute", "kind": "tool"])
        wiring.addRaw(["id": "r2", "provider": "x", "name": "execute", "kind": "tool", "title": "", "input": [String: Any](),
                       "detail": ["type": "unknown", "input": ["reason": NSNull()], "output": NSNull()]])
        #expect(wiring.board.prompts.isEmpty)
        // Left to Paseo, so it can be answered there; and a title that says something is enough for a card.
        wiring.addRaw(["id": "r3", "provider": "x", "name": "execute", "kind": "tool", "title": "Run ls"])
        #expect(wiring.board.prompts.count == 1)
    }

    @Test func theTitleOfARequestWithInputDoesNotReplaceTheCardsOwn() throws {
        let wiring = Wiring()
        wiring.add(name: "Bash", input: ["command": "rm -rf build"])
        #expect(try #require(wiring.board.current).title == String(localized: "Run a command"))
        let other = Wiring()
        other.add(name: "mcp__github__create_issue", input: ["title": "Bug"])
        #expect(try #require(other.board.current).title.contains("create_issue"))
    }

    @Test func onlyAToolCallGetsACard() {
        let wiring = Wiring()
        for kind in ["plan", "question", "mode", "other"] { wiring.add("r-\(kind)", kind: kind) }
        wiring.add("r-exit", name: "ExitPlanMode", input: ["plan": "x"])
        #expect(wiring.board.prompts.isEmpty)
        // A call too large to show whole is left to Paseo as the hooks' are.
        wiring.add("r-big", input: ["command": String(repeating: "a", count: PermissionPrompt.detailLimit + 1)])
        #expect(wiring.board.prompts.isEmpty)
    }

    @Test func allowAndDenyGoToTheDaemonWithTheSameAgentAndRequest() throws {
        let wiring = Wiring()
        wiring.add("r1")
        wiring.add("r2")
        wiring.board.answer(try #require(wiring.board.current), .allow)
        wiring.board.answer(try #require(wiring.board.current), .deny)
        #expect(wiring.sent == [Sent(agent: agentA, request: "r1", allow: true), Sent(agent: agentA, request: "r2", allow: false)])
        #expect(wiring.board.prompts.isEmpty)
    }

    @Test func answerInPaseoLeavesItPendingAndDoesNotBringItBack() throws {
        let wiring = Wiring()
        wiring.add("r1")
        wiring.board.answer(try #require(wiring.board.current), .terminal)
        #expect(wiring.sent.isEmpty && wiring.board.prompts.isEmpty)
        // A listing that still holds it does not bring it up again.
        wiring.add("r1")
        #expect(wiring.board.prompts.isEmpty)
        wiring.add("r2")
        #expect(wiring.board.prompts.count == 1)
    }

    @Test func anAnswerThatCouldNotBeSentBringsTheCardBack() throws {
        let wiring = Wiring()
        wiring.add("r1")
        wiring.connected = false
        let prompt = try #require(wiring.board.current)
        wiring.board.answer(prompt, .allow)
        #expect(wiring.sent.isEmpty && wiring.board.prompts.map(\.id) == [prompt.id])
        wiring.connected = true
        wiring.board.answer(prompt, .deny)
        #expect(wiring.sent == [Sent(agent: agentA, request: "r1", allow: false)] && wiring.board.prompts.isEmpty)
    }

    @Test func aRequestAnsweredInPaseoTakesItsCardDownAndItsOldCardIsNotOurs() throws {
        let wiring = Wiring()
        wiring.add("r1")
        let prompt = try #require(wiring.board.current)
        wiring.approvals.removed(request: "r1")
        #expect(wiring.board.prompts.isEmpty && !wiring.approvals.answer(prompt.id, .allow) && wiring.sent.isEmpty)
        // A card of the hooks' is none of ours.
        #expect(!wiring.approvals.answer(UUID(), .allow))
        // The same request may come again once it is gone (a new one with the same id is a new one).
        wiring.add("r1")
        #expect(wiring.board.prompts.count == 1)
    }

    @Test func aCardIsNotMadeTwiceForOneRequest() {
        let wiring = Wiring()
        wiring.add("r1")
        wiring.add("r1")
        #expect(wiring.board.prompts.count == 1)
    }

    @Test func withTheSettingOffThereAreNoCardsAndResetTakesDownTheOnesThatWere() {
        let off = Wiring(enabled: false)
        off.add()
        #expect(off.board.prompts.isEmpty)
        let wiring = Wiring()
        wiring.add("r1")
        wiring.add("r2")
        wiring.approvals.reset()
        #expect(wiring.board.prompts.isEmpty)
    }

    @Test func theBodyIsTheOneTheHooksParserReads() throws {
        let permission = PaseoPermission(id: "r1", name: "Edit", input: Data(#"{"file_path":"/tmp/a.txt","old_string":"a","new_string":"b"}"#.utf8))
        let body = try #require(PaseoApprovals.body(permission, folder: "/Users/me/work/api"))
        let parsed = object(String(decoding: body, as: UTF8.self))
        #expect(parsed["hook_event_name"] as? String == "PermissionRequest" && parsed["tool_name"] as? String == "Edit" && parsed["cwd"] as? String == "/Users/me/work/api")
        #expect((parsed["tool_input"] as? [String: Any])?["file_path"] as? String == "/tmp/a.txt")
        #expect(PermissionPrompt.parse(body, tag: "Paseo")?.prompt.title == String(localized: "Edit a file"))
        // No input at all is an empty one.
        let bare = try #require(PaseoApprovals.body(PaseoPermission(id: "r2", name: "Bash"), folder: ""))
        #expect((object(String(decoding: bare, as: UTF8.self))["tool_input"] as? [String: Any])?.isEmpty == true)
    }
}

@MainActor
struct PaseoWatcherTests {
    private let now = paseoStart.addingTimeInterval(60)
    private let cliURL = URL(fileURLWithPath: "/Applications/Paseo.app/Contents/Resources/bin/paseo")

    @MainActor private final class Fixture {
        let home = PaseoHome()
        let board = AgentBoard()
        let permissions = PermissionBoard()
        let sockets = PaseoSockets()
        var onScreen = true
        var approvals = true
        var notices = true
        var front: String?
        var watcher: PaseoWatcher!
        var notes: [PaseoNotice] = []
        /// What the watcher's clock says; moved by hand.
        var current: Date
        let refusal = PaseoRefusal()

        init(now: Date, cli: URL?) {
            current = now
            watcher = PaseoWatcher(board: board, permissions: permissions, isOn: { [unowned self] in onScreen }, wantsApprovals: { [unowned self] in approvals },
                                   wantsNotices: { [unowned self] in notices }, home: home.url, now: { [unowned self] in current }, isAlive: { _ in true }, bootTime: { nil },
                                   cli: { cli }, frontmostApp: { [unowned self] in front }, clientID: "nunsseop_test",
                                   socket: { [sockets] in sockets.make($0) }, timing: quickTiming, refusal: refusal)
            watcher.onNotice = { [unowned self] in notes.append($0) }
            permissions.onAnswer = { [unowned self] in _ = watcher.approvals.answer($0, $1) }
        }

        func entry(_ id: String = paseoAgentID) -> AgentBoard.Agent? { board.entries(now: paseoStart.addingTimeInterval(60)).first { $0.source == Paseo.source && $0.id == id }?.agent }
        func connect() async -> FakePaseoSocket? {
            await eventually { !self.sockets.all.isEmpty && !self.sockets.all[0].sent.isEmpty }
            guard let socket = sockets.all.first else { return nil }
            socket.push(serverInfo())
            await eventually { self.watcher.client.state == .ready }
            return socket
        }
    }

    private func make(cli: URL? = nil) -> Fixture { Fixture(now: now, cli: cli ?? cliURL) }

    @Test func theBoardListsTheAgentsOfTheRecordsWhileTheCountIsShown() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.home.agent(paseoRecord(status: "running", updated: paseoStart))
        fixture.home.agent(paseoRecord(id: "6f1b2c3d-0000-4000-8000-000000000002", status: "idle", updated: paseoStart.addingTimeInterval(-60), title: "Old"))
        fixture.watcher.poll()
        await eventually { fixture.entry() != nil }
        let agent = try #require(fixture.entry())
        #expect(agent.state == .working && agent.input == .paseo(agent: paseoAgentID, server: "srv_abc123") && agent.host == "Paseo")
        #expect(fixture.entry("6f1b2c3d-0000-4000-8000-000000000002")?.state == .idle)
        // As of the test's clock: the board's own timer for the old row's expiry counts by the real one, which is years on.
        #expect(fixture.board.entries(now: now).filter { $0.agent.state == .working }.count == 1)
        fixture.watcher.stop()
    }

    @Test func nothingIsReadWhileNeitherTheCountNorTheTabIsShown() async throws {
        let fixture = make()
        fixture.onScreen = false
        fixture.approvals = false
        fixture.notices = false
        fixture.home.daemon()
        fixture.home.agent(paseoRecord(status: "running", updated: paseoStart))
        fixture.watcher.poll()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(fixture.entry() == nil && fixture.sockets.all.isEmpty)
        // Showing the count reads them.
        fixture.onScreen = true
        fixture.watcher.poll()
        await eventually { fixture.entry() != nil }
        #expect(fixture.entry() != nil)
        // Showing it no longer forgets them.
        fixture.onScreen = false
        fixture.watcher.poll()
        await eventually { fixture.entry() == nil }
        #expect(fixture.entry() == nil)
        fixture.watcher.stop()
    }

    @Test func withoutADaemonTheBoardIsEmptyAndNoSocketIsMade() async throws {
        let fixture = make()
        fixture.home.agent(paseoRecord(status: "running", updated: paseoStart))
        fixture.watcher.poll()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(fixture.entry() == nil && fixture.sockets.all.isEmpty && fixture.watcher.client.state == .stopped)
        fixture.watcher.stop()
    }

    @Test func aDaemonWithAPasswordOrOnASocketIsNotConnectedToButStillListed() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.home.config(["daemon": ["auth": ["password": "$2b$12$x"]]])
        fixture.home.agent(paseoRecord(status: "running", updated: paseoStart))
        fixture.watcher.poll()
        await eventually { fixture.entry() != nil }
        #expect(fixture.sockets.all.isEmpty && fixture.entry()?.state == .working)
        let other = make()
        other.home.daemon(listen: "/tmp/paseo.sock")
        other.home.agent(paseoRecord(status: "running", updated: paseoStart))
        other.watcher.poll()
        await eventually { other.entry() != nil }
        #expect(other.sockets.all.isEmpty)
        fixture.watcher.stop()
        other.watcher.stop()
    }

    @Test func theConnectionRunsOnlyWhileCardsOrNoticesAreWanted() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.approvals = false
        fixture.notices = false
        fixture.watcher.poll()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fixture.sockets.all.isEmpty)
        fixture.notices = true
        fixture.watcher.poll()
        await eventually { !fixture.sockets.all.isEmpty }
        #expect(fixture.sockets.urls == [URL(string: "ws://127.0.0.1:6767/ws")!])
        fixture.notices = false
        fixture.watcher.poll()
        await eventually { fixture.watcher.client.state == .stopped }
        #expect(fixture.watcher.client.state == .stopped)
        fixture.watcher.stop()
    }

    @Test func aRequestTurnsTheAgentToWaitingAndShowsACardWhoseAnswerReachesTheDaemon() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.home.agent(paseoRecord(status: "running", updated: paseoStart))
        fixture.watcher.poll()
        await eventually { fixture.entry() != nil }
        let socket = try #require(await fixture.connect())
        socket.push(requested(paseoAgentID, permission("req-1", input: ["command": "npm test"])))
        await eventually { fixture.entry()?.state == .waiting && !fixture.permissions.prompts.isEmpty }
        let prompt = try #require(fixture.permissions.current)
        #expect(fixture.entry()?.finished == false && fixture.board.counts == AgentBoard.Counts(working: 0, waiting: 1))
        #expect(prompt.tag == "Paseo" && prompt.detail.contains("npm test") && prompt.folder == "api")
        fixture.permissions.answer(prompt, .allow)
        await eventually { !socket.sent("agent_permission_response").isEmpty }
        let answer = try #require(socket.sent("agent_permission_response").first?["message"] as? [String: Any])
        #expect(answer["agentId"] as? String == paseoAgentID && answer["requestId"] as? String == "req-1" && (answer["response"] as? [String: String]) == ["behavior": "allow"])
        // The daemon says it is resolved: the agent works again.
        socket.push(resolved(paseoAgentID, "req-1"))
        await eventually { fixture.entry()?.state == .working }
        #expect(fixture.entry()?.state == .working)
        fixture.watcher.stop()
    }

    @Test func switchingTheCardsOffTakesThemDownAndSwitchingThemOnBringsBackTheWaitingOnes() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.watcher.poll()
        let socket = try #require(await fixture.connect())
        socket.push(requested(paseoAgentID, permission("req-1")))
        await eventually { !fixture.permissions.prompts.isEmpty }
        fixture.approvals = false
        fixture.watcher.poll()
        #expect(fixture.permissions.prompts.isEmpty)
        fixture.approvals = true
        fixture.watcher.poll()
        #expect(fixture.permissions.prompts.count == 1)
        fixture.watcher.stop()
    }

    @Test func aFinishedOrFailedAgentIsAnnouncedAndOtherThingsAreNot() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.home.agent(paseoRecord(status: "idle", title: "Fix the build"))
        fixture.watcher.poll()
        let socket = try #require(await fixture.connect())
        socket.push(attention(paseoAgentID, "finished"))
        await eventually { !fixture.notes.isEmpty }
        let note = try #require(fixture.notes.first)
        #expect(note.title == "Paseo · Fix the build" && note.detail == String(localized: "Finished"))
        // The same event again within a moment is the same notice; a permission is the card's business; another agent, another notice.
        socket.push(attention(paseoAgentID, "finished"))
        socket.push(attention(paseoAgentID, "permission"))
        socket.push(attention("6f1b2c3d-0000-4000-8000-0000000000ff", "finished"))
        socket.push(attention(paseoAgentID, "error"))
        await eventually { fixture.notes.count >= 3 }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fixture.notes.count == 3)
        // An agent the files don't know is named by its id.
        #expect(fixture.notes.map(\.title) == ["Paseo · Fix the build", "Paseo · 6f1b2c3d", "Paseo · Fix the build"])
        #expect(fixture.notes.map(\.detail) == [String(localized: "Finished"), String(localized: "Finished"), String(localized: "Stopped with an error")])
        fixture.watcher.stop()
    }

    @Test func nothingIsAnnouncedWhileThePaseoAppIsInFrontOrNoticesAreOff() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.front = Paseo.bundleID
        fixture.watcher.poll()
        let socket = try #require(await fixture.connect())
        socket.push(attention(paseoAgentID, "finished"))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(fixture.notes.isEmpty)
        fixture.front = "com.apple.Terminal"
        fixture.notices = false
        fixture.approvals = true
        socket.push(attention(paseoAgentID, "error"))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(fixture.notes.isEmpty)
        fixture.watcher.stop()
    }

    @Test func aRefusedHelloReachesTheStatusSettingsShows() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.watcher.poll()
        await eventually { !fixture.sockets.all.isEmpty && !fixture.sockets.all[0].sent.isEmpty }
        #expect(!fixture.refusal.value)
        // The daemon was given a password in its environment: nothing in its files says so, only this answer.
        fixture.sockets.all[0].push(#"{"type":"hello.rejected","reason":"password_required","accepts":["password"]}"#)
        await eventually { fixture.refusal.value }
        #expect(fixture.watcher.client.state == .refused && fixture.refusal.value)
        let status = PaseoStatus.current(home: fixture.home.url, app: nil, isAlive: { _ in true }, bootTime: nil, refused: fixture.refusal.value)
        #expect(status.daemonRunning && !status.approvalsAvailable)
        // Switched off, the refusal is forgotten.
        fixture.notices = false
        fixture.approvals = false
        fixture.watcher.poll()
        await eventually { !fixture.refusal.value }
        #expect(!fixture.refusal.value)
        fixture.watcher.stop()
    }

    /// A turn started from the notch while an earlier finish is unread: the record has the first finish's flag and timestamp.
    private func secondFinish(_ fixture: Fixture) {
        fixture.home.agent(paseoRecord(status: "idle", updated: paseoStart.addingTimeInterval(40), title: "Fix the build", attention: "finished",
                                       attentionAt: paseoStart.addingTimeInterval(-7_200)))
    }

    @Test func aFinishWithoutAnEventBecauseTheFlagWasStillSetIsAnnouncedWhenTheRowTurnsFromWorkToFinished() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.home.agent(paseoRecord(status: "running", updated: paseoStart.addingTimeInterval(10), title: "Fix the build", attention: "finished",
                                       attentionAt: paseoStart.addingTimeInterval(-7_200)))
        fixture.watcher.poll()
        await eventually { fixture.entry()?.state == .working }
        #expect(fixture.notes.isEmpty)
        fixture.current = paseoStart.addingTimeInterval(45)
        secondFinish(fixture)
        fixture.watcher.poll()
        await eventually { !fixture.notes.isEmpty }
        let note = try #require(fixture.notes.first)
        #expect(note.title == "Paseo · Fix the build" && note.detail == String(localized: "Finished"))
        // It reads as a fresh hand, not as one from two hours ago.
        let agent = try #require(fixture.entry())
        #expect(agent.state == .waiting && agent.finished && agent.since == paseoStart.addingTimeInterval(40))
        // Looking again says nothing new.
        fixture.watcher.poll()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(fixture.notes.count == 1)
        fixture.watcher.stop()
    }

    @Test func aFinishTheDaemonAnnouncedIsNotAnnouncedAgainWhenTheRowCatchesUp() async throws {
        let fixture = make()
        fixture.home.daemon()
        fixture.home.agent(paseoRecord(status: "running", updated: paseoStart.addingTimeInterval(10), title: "Fix the build"))
        fixture.watcher.poll()
        let socket = try #require(await fixture.connect())
        await eventually { fixture.entry()?.state == .working }
        // The event comes before the record is written; well after the 3 seconds that fold two events into one.
        fixture.current = paseoStart.addingTimeInterval(50)
        socket.push(attention(paseoAgentID, "finished"))
        await eventually { fixture.notes.count == 1 }
        fixture.current = paseoStart.addingTimeInterval(58)
        fixture.home.agent(paseoRecord(status: "idle", updated: paseoStart.addingTimeInterval(49), title: "Fix the build", attention: "finished",
                                       attentionAt: paseoStart.addingTimeInterval(49)))
        fixture.watcher.poll()
        await eventually { fixture.entry()?.finished == true }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(fixture.notes.count == 1)
        fixture.watcher.stop()
    }

    @Test func theClientIDIsKeptForNextTime() {
        let defaults = UserDefaults(suiteName: "nunsseop-paseo-test-\(UUID().uuidString)")!
        let first = PaseoWatcher.clientID(defaults: defaults)
        #expect(first.hasPrefix("nunsseop_") && first.count > 20 && PaseoWatcher.clientID(defaults: defaults) == first)
    }
}

// MARK: A stand-in daemon on the loopback

/// Enough of the daemon's WebSocket for a client to talk to: it answers the hello, lists a running agent with a request waiting, makes
/// another request after the subscription, and resolves what it is answered. It listens on the loopback only.
private final class StandInDaemon: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nunsseop.paseo.standin")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var texts: [String] = []

    var received: [[String: Any]] { lock.withLock { texts.map(object) } }

    func start() async -> UInt16? {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return await withCheckedContinuation { continuation in
            let answered = Answered()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: answered.once { continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled: answered.once { continuation.resume(returning: nil) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Runs what it is given the first time only.
    private final class Answered: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func once(_ work: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { work() }
        }
    }

    func stop() {
        listener?.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        read(connection)
    }

    private func read(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let data, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, metadata.opcode == .text {
                handle(String(decoding: data, as: UTF8.self), on: connection)
            }
            read(connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func handle(_ text: String, on connection: NWConnection) {
        lock.withLock { texts.append(text) }
        let message = object(text)
        let inner = message["message"] as? [String: Any]
        switch (message["type"] as? String, inner?["type"] as? String) {
        case ("hello", _):
            send(serverInfo(), on: connection)
        case ("ping", _):
            send(#"{"type":"pong"}"#, on: connection)
        case ("session", "fetch_agents_request"?):
            let request = inner?["requestId"] as? String ?? ""
            send(listing(request, [agentA: [permission("req-listed", input: ["command": "git status"])]]), on: connection)
        case ("session", "session.events.set_subscription.request"?):
            // After the listing, as a request made while the user works would arrive.
            queue.asyncAfter(deadline: .now() + 0.2) { [self] in send(requested(agentB, permission("req-event", input: ["command": "ls"])), on: connection) }
        case ("session", "agent_permission_response"?):
            send(resolved(inner?["agentId"] as? String ?? "", inner?["requestId"] as? String ?? ""), on: connection)
        default:
            break
        }
    }
}

@MainActor
struct PaseoLoopbackTests {
    @Test func theRealSocketTalksToAStandInDaemonEndToEnd() async throws {
        let daemon = StandInDaemon()
        let port = try #require(await daemon.start())
        defer { daemon.stop() }
        var added: [String] = []
        var removed: [String] = []
        let client = PaseoClient(endpoint: { URL(string: "ws://127.0.0.1:\(port)/ws") }, clientID: "nunsseop_loop")
        client.onAdded = { added.append($1.id) }
        client.onRemoved = { removed.append($1) }
        client.start()
        await eventually { client.state == .ready && added.count >= 2 }
        #expect(client.state == .ready && Set(added) == ["req-listed", "req-event"])
        #expect(client.pendingAgents == [agentA, agentB])
        // What the daemon was told: hello first, with the identity; then the subscription and the listing.
        let first = try #require(daemon.received.first)
        #expect(first["type"] as? String == "hello" && first["clientId"] as? String == "nunsseop_loop" && first["clientType"] as? String == "cli" && first["protocolVersion"] as? Int == 1)
        let types = daemon.received.compactMap { ($0["message"] as? [String: Any])?["type"] as? String }
        #expect(types.contains("session.events.set_subscription.request") && types.contains("fetch_agents_request"))
        // An answer reaches it as the protocol has it, and the daemon's "resolved" takes the request away.
        #expect(client.respond(agent: agentB, request: "req-event", allow: true))
        await eventually { removed.contains("req-event") }
        let answer = daemon.received.compactMap { $0["message"] as? [String: Any] }.first { $0["type"] as? String == "agent_permission_response" }
        #expect(answer?["agentId"] as? String == agentB && answer?["requestId"] as? String == "req-event" && (answer?["response"] as? [String: String]) == ["behavior": "allow"])
        #expect(removed == ["req-event"] && client.pendingAgents == [agentA])
        client.stop()
    }

    @Test func aDaemonThatIsNotThereIsWaitedForNotCrashedInto() async throws {
        // A port nobody listens on: the listener is closed at once.
        let daemon = StandInDaemon()
        let port = try #require(await daemon.start())
        daemon.stop()
        var timing = quickTiming
        timing.retry = [0.05]
        let client = PaseoClient(endpoint: { URL(string: "ws://127.0.0.1:\(port)/ws") }, clientID: "nunsseop_loop", timing: timing)
        client.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(client.state != .ready && client.pendingAgents.isEmpty)
        client.stop()
    }
}

struct PaseoTranslationTests {
    @Test func theNewSentencesAreTranslatedIntoEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let keys = ["Paseo would interrupt its turn: message it once it is done", "Paseo's command line wasn't found, so Nunsseop can't send to this agent",
                    "Couldn't open this conversation in Paseo", "Open in Paseo", "Answer in Paseo", "Stopped with an error", "Paseo daemon running",
                    "Paseo daemon not running", "command line found", "command line not found", "Show when agents in Paseo finish or fail",
                    "Paseo's tool approvals show in the notch too, where you can allow or deny them. “Answer in Paseo” leaves one for Paseo's own screens, and the notch lets go of one you answer there.",
                    "Paseo's daemon asks for a password or listens on a socket, so its approvals and notices can't show here.",
                    "Its agents are read from Paseo's own files, and its approvals and notices from its daemon on this Mac, which Nunsseop never starts. Messages go through its command line."]
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for key in keys {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language): \(key)"))
            }
        }
    }
}
