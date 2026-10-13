import Foundation

/// What a permission request of Paseo's carries (`AgentPermissionRequestPayloadSchema`, protocol/src/messages.ts): its id, the tool's
/// name and input as the agent's tool sent them, and `kind`, which is `tool` for a tool call and `plan`, `question`, `mode` or `other`
/// for what only Paseo's own screens can answer. Claude's requests carry the tool's `input`; many others do not (an ACP provider's
/// has the tool kind as `name`, say `execute`, and its words in `title` and `detail`; Codex's file change only a generic title and the
/// optional reason), so `title`, `summary` (the `description`) and `detail` are kept for the card.
struct PaseoPermission: Equatable {
    let id: String
    let name: String
    let kind: String
    var title: String?
    var summary: String?
    /// The tool's `input` object as JSON.
    var input: Data?
    /// What `detail` says (a command, a file path and its text, a query...) as a flat JSON object without its nulls; nil when it says nothing.
    var detail: Data?

    init(id: String, name: String, kind: String = "tool", title: String? = nil, summary: String? = nil, input: Data? = nil, detail: Data? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.title = title
        self.summary = summary
        self.input = input
        self.detail = detail
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty, let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.init(id: id, name: name, kind: json["kind"] as? String ?? "other", title: json["title"] as? String, summary: json["description"] as? String,
                  input: (json["input"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) },
                  detail: Self.fields(of: json["detail"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
    }

    /// A `ToolCallDetail` (`shell`, `edit`, `write`, `plain_text`...) as the fields that say something: an `unknown` one is its `input`,
    /// the `type` tag and the nulls and empty texts are left out. nil when nothing is left.
    static func fields(of detail: [String: Any]?) -> [String: Any]? {
        guard var fields = detail else { return nil }
        if fields["type"] as? String == "unknown" { fields = fields["input"] as? [String: Any] ?? [:] }
        fields["type"] = nil
        fields = fields.filter { !($0.value is NSNull) && ($0.value as? String).map { !$0.isEmpty } != false }
        return fields.isEmpty ? nil : fields
    }

    /// The tool's input, empty when the request has none.
    var toolInput: [String: Any] { input.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:] }

    /// What the card is made from when the request has no `input`: the title, the description and the detail, as the fields of a tool
    /// input, so the card lists them. Empty when the request says nothing of what it asks.
    var shown: [String: Any] {
        var fields = detail.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        for (key, value) in [("title", title), ("description", summary)] {
            if let value, !value.isEmpty { fields[key] = value }
        }
        return fields
    }
}

/// The messages between Nunsseop and the daemon's WebSocket at `/ws`, as the protocol of Paseo's source has them
/// (protocol/src/messages.ts; the client that speaks it is client/src/daemon-client.ts). Only what the approvals and the notices need:
/// - `hello` comes first, as `WSHelloMessageSchema` has it, and everything else travels as `{"type":"session","message":...}`;
/// - the daemon answers a hello with a `status` message (`server_info`), and a password it wants with `hello.rejected`;
/// - events reach a client that asked for them with `session.events.set_subscription.request` and says it owns its subscriptions
///   (the capabilities of the hello); `ping` is answered by `pong`, and a client that pings has to keep pinging: the daemon lets go of a
///   socket 45 s after its last one;
/// - a permission is answered by `agent_permission_response`, with `{behavior: allow}` or `{behavior: deny}`, the same two the command
///   line's `permit allow` and `permit deny` send.
enum PaseoWire {
    static let protocolVersion = 1
    static let requestPrefix = "nunsseop-"
    /// The capabilities Nunsseop declares: that it names its events and owns its subscriptions (so it is sent nothing it didn't ask for),
    /// reads a refused hello, and takes every provider's agents.
    static let capabilities = ["hello_rejection", "owned_subscriptions", "explicit_event_subscriptions", "selective_agent_timeline", "all_providers"]
    static let events = ["agent_permission_request", "agent_permission_resolved", "agent_attention_required"]
    static let ping = #"{"type":"ping"}"#

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func session(_ message: [String: Any]) -> String { json(["type": "session", "message": message]) }

    /// No `appVersion`: the daemon compares it with Paseo's own version series to decide what an old client can be sent, and Nunsseop's
    /// number means nothing there; the capabilities say what it takes.
    static func hello(clientID: String) -> String {
        json(["type": "hello", "clientId": clientID, "clientType": "cli", "protocolVersion": protocolVersion,
              "capabilities": Dictionary(uniqueKeysWithValues: capabilities.map { ($0, true) })])
    }

    static func subscribe(request: String) -> String {
        session(["type": "session.events.set_subscription.request", "requestId": request, "events": events])
    }

    /// The agents that are running, the ones with a permission waiting first: they hold the requests that were asked before Nunsseop connected.
    static func running(request: String) -> String {
        session(["type": "fetch_agents_request", "requestId": request, "filter": ["statuses": ["running"]],
                 "sort": [["key": "status_priority", "direction": "asc"]], "page": ["limit": 100]])
    }

    static func answer(agent: String, request: String, allow: Bool) -> String {
        session(["type": "agent_permission_response", "agentId": agent, "requestId": request, "response": ["behavior": allow ? "allow" : "deny"]])
    }

    enum Inbound: Equatable {
        case serverInfo(String)
        case rejected(String)
        case requested(agent: String, PaseoPermission)
        case resolved(agent: String, request: String)
        /// The permissions waiting on each of the listed agents.
        case listing(request: String, [String: [PaseoPermission]])
        case attention(agent: String, reason: String)
        case pong
        case other
    }

    static func decode(_ text: String) -> Inbound {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let type = object["type"] as? String else { return .other }
        switch type {
        case "pong": return .pong
        case "hello.rejected": return .rejected(object["reason"] as? String ?? "")
        case "session": break
        default: return .other
        }
        guard let message = object["message"] as? [String: Any], let kind = message["type"] as? String,
              let payload = message["payload"] as? [String: Any] else { return .other }
        switch kind {
        case "status":
            guard payload["status"] as? String == "server_info", let id = payload["serverId"] as? String, !id.isEmpty else { return .other }
            return .serverInfo(id)
        case "agent_permission_request":
            guard let agent = payload["agentId"] as? String, let request = (payload["request"] as? [String: Any]).flatMap(PaseoPermission.init(json:)) else { return .other }
            return .requested(agent: agent, request)
        case "agent_permission_resolved":
            guard let agent = payload["agentId"] as? String, let request = payload["requestId"] as? String else { return .other }
            return .resolved(agent: agent, request: request)
        case "agent_attention_required":
            guard let agent = payload["agentId"] as? String, let reason = payload["reason"] as? String else { return .other }
            return .attention(agent: agent, reason: reason)
        case "fetch_agents_response":
            guard let request = payload["requestId"] as? String, let entries = payload["entries"] as? [[String: Any]] else { return .other }
            var listed: [String: [PaseoPermission]] = [:]
            for entry in entries {
                guard let agent = entry["agent"] as? [String: Any], let id = agent["id"] as? String else { continue }
                let permissions = (agent["pendingPermissions"] as? [[String: Any]])?.compactMap(PaseoPermission.init(json:)) ?? []
                if !permissions.isEmpty { listed[id] = permissions }
            }
            return .listing(request: request, listed)
        default: return .other
        }
    }
}

/// One WebSocket to the daemon. The real one is `URLSessionPaseoSocket`; tests give another.
protocol PaseoSocket: AnyObject {
    func send(_ text: String) async throws
    /// The next text frame; throws when the connection ends. Binary frames (terminals) are not asked for and are skipped.
    func receive() async throws -> String
    func close()
}

final class URLSessionPaseoSocket: PaseoSocket {
    private let session = URLSession(configuration: .ephemeral)
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        task = session.webSocketTask(with: URLRequest(url: url, timeoutInterval: 10))
        // A listing of a hundred agents is bigger than the default megabyte allows.
        task.maximumMessageSize = 16 << 20
        task.resume()
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        while true {
            if case .string(let text) = try await task.receive() { return text }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// The permissions waiting in Paseo, kept current from its daemon. It connects to a daemon on this Mac that has no password, says hello
/// as a command-line client, asks for the permission and attention events and for the agents that are running (which hold the requests
/// made before it connected), and tells what became pending and what is no longer. It never starts the daemon: while there is none to
/// reach it waits, and a refused hello (a password) is not tried again for `Timing.refused`.
@MainActor
final class PaseoClient {
    enum State: Equatable {
        case stopped
        /// No daemon to reach, or the connection was lost.
        case waiting
        case connecting
        case ready
        /// The daemon asked for a password.
        case refused
    }

    struct Timing {
        var idle: TimeInterval = 5
        var refused: TimeInterval = 120
        var retry: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        var ping: TimeInterval = 10
        /// How long without a `pong` before the connection is taken for dead.
        var silence: TimeInterval = 25
        /// How often the listing of running agents is read again, in case an event was lost.
        var relist: TimeInterval = 30
    }

    private(set) var state = State.stopped {
        didSet { if state != oldValue { onState?(state) } }
    }
    var onState: ((State) -> Void)?
    var onAdded: ((_ agent: String, PaseoPermission) -> Void)?
    var onRemoved: ((_ agent: String, _ request: String) -> Void)?
    var onAttention: ((_ agent: String, _ reason: String) -> Void)?

    /// What is waiting, by agent, and the listing it was last seen in: a request an event brought stays until a listing sent after it
    /// leaves it out.
    private var pending: [String: [String: (permission: PaseoPermission, epoch: Int)]] = [:]
    private var listings = 0
    private var requests = 0

    private let endpoint: () -> URL?
    private let makeSocket: (URL) -> PaseoSocket
    private let clientID: String
    private let timing: Timing
    private var task: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var socket: PaseoSocket?
    private let clock: () -> Date
    /// When the daemon last answered, by `clock`.
    private(set) var lastPong: Date

    /// - endpoint: where the daemon is now, nil while there is none to reach; asked for again on each attempt.
    /// - clock: what tells how long the daemon has been silent; tests give one they move by hand.
    init(endpoint: @escaping () -> URL?, clientID: String, timing: Timing = Timing(), clock: @escaping () -> Date = { .now },
         socket makeSocket: @escaping (URL) -> PaseoSocket = { URLSessionPaseoSocket(url: $0) }) {
        self.endpoint = endpoint
        self.clientID = clientID
        self.clock = clock
        lastPong = clock()
        self.timing = timing
        self.makeSocket = makeSocket
    }

    /// The agents that have a permission waiting.
    var pendingAgents: Set<String> { Set(pending.filter { !$0.value.isEmpty }.keys) }

    /// Every request that waits, with its agent.
    var pendingRequests: [(agent: String, permission: PaseoPermission)] {
        pending.flatMap { agent, requests in requests.values.map { (agent, $0.permission) } }
    }

    func start() {
        guard task == nil else { return }
        state = .waiting
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        pinger?.cancel()
        pinger = nil
        socket?.close()
        socket = nil
        forgetAll()
        state = .stopped
    }

    /// Answers a request. False when there is no connection to send it on, and nothing was sent.
    @discardableResult
    func respond(agent: String, request: String, allow: Bool) -> Bool {
        guard state == .ready, let socket else { return false }
        let text = PaseoWire.answer(agent: agent, request: request, allow: allow)
        Task { try? await socket.send(text) }
        return true
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.001) * 1_000_000_000))
    }

    private enum Outcome {
        case refused
        case ended(reached: Bool)
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            guard let url = endpoint() else {
                state = .waiting
                await pause(timing.idle)
                continue
            }
            let outcome = await connect(url)
            if Task.isCancelled { return }
            switch outcome {
            case .refused:
                state = .refused
                await pause(timing.refused)
            case .ended(let reached):
                failures = reached ? 0 : failures + 1
                state = .waiting
                await pause(timing.retry[min(max(failures - 1, 0), timing.retry.count - 1)])
            }
        }
    }

    private func connect(_ url: URL) async -> Outcome {
        let socket = makeSocket(url)
        self.socket = socket
        state = .connecting
        var reached = false
        defer {
            socket.close()
            // Only the connection that is still the current one: after `stop()` and a new `start()`, an old one ending late must not
            // take the new one's pings and requests with it.
            if self.socket === socket {
                self.socket = nil
                pinger?.cancel()
                pinger = nil
                forgetAll()
            }
        }
        do {
            try await socket.send(PaseoWire.hello(clientID: clientID))
            while true {
                switch PaseoWire.decode(try await socket.receive()) {
                case .rejected:
                    return .refused
                case .serverInfo:
                    guard !reached else { continue }
                    reached = true
                    state = .ready
                    lastPong = clock()
                    try await socket.send(PaseoWire.subscribe(request: nextRequest()))
                    try await list(on: socket)
                    startPinging(socket)
                case .pong:
                    lastPong = clock()
                case .listing(let request, let agents) where request.hasPrefix(PaseoWire.requestPrefix):
                    reconcile(agents, listing: Int(request.split(separator: "-").last ?? "") ?? listings)
                case .requested(let agent, let permission):
                    add(permission, to: agent, epoch: listings)
                case .resolved(let agent, let request):
                    remove(request, from: agent)
                case .attention(let agent, let reason):
                    onAttention?(agent, reason)
                case .listing, .other:
                    break
                }
            }
        } catch {
            return .ended(reached: reached)
        }
    }

    private func nextRequest() -> String {
        requests += 1
        return "\(PaseoWire.requestPrefix)\(requests)"
    }

    /// Asks for the running agents. The listing's own number is the last part of its request id, which the answer carries back.
    private func list(on socket: PaseoSocket) async throws {
        listings += 1
        try await socket.send(PaseoWire.running(request: "\(PaseoWire.requestPrefix)list-\(listings)"))
    }

    private func startPinging(_ socket: PaseoSocket) {
        pinger?.cancel()
        let timing = timing
        pinger = Task { [weak self] in
            var sinceListing: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(timing.ping * 1_000_000_000))
                guard !Task.isCancelled, let self, self.socket === socket else { return }
                if self.clock().timeIntervalSince(self.lastPong) > timing.silence {
                    // Closing ends the read, which ends the connection.
                    socket.close()
                    return
                }
                try? await socket.send(PaseoWire.ping)
                sinceListing += timing.ping
                if sinceListing >= timing.relist {
                    sinceListing = 0
                    try? await self.list(on: socket)
                }
            }
        }
    }

    // MARK: Pending

    private func add(_ permission: PaseoPermission, to agent: String, epoch: Int) {
        guard pending[agent]?[permission.id] == nil else { return }
        pending[agent, default: [:]][permission.id] = (permission, epoch)
        onAdded?(agent, permission)
    }

    private func remove(_ request: String, from agent: String) {
        guard pending[agent]?.removeValue(forKey: request) != nil else { return }
        if pending[agent]?.isEmpty == true { pending[agent] = nil }
        onRemoved?(agent, request)
    }

    /// A listing, answering the `listing`th one sent: what it holds is pending, and what it leaves out is not, unless an event
    /// brought it after that listing was asked for (the answer is as of its asking).
    private func reconcile(_ agents: [String: [PaseoPermission]], listing: Int) {
        for (agent, permissions) in agents {
            for permission in permissions { add(permission, to: agent, epoch: listing) }
        }
        for (agent, requests) in pending {
            for (id, entry) in requests where entry.epoch < listing && !(agents[agent]?.contains { $0.id == id } ?? false) {
                remove(id, from: agent)
            }
        }
    }

    private func forgetAll() {
        let all = pending
        pending = [:]
        for (agent, requests) in all {
            for id in requests.keys { onRemoved?(agent, id) }
        }
    }
}
