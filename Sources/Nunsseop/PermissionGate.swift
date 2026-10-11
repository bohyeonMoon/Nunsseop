import Foundation
import Network

/// The server's side of `POST /permission`: checks the hook's proof, shows the prompt, and holds the hook's connection
/// until the user answers, the hook goes away (the terminal answered first) or the time runs out. Everything here runs
/// on the server's queue. Held connections are counted apart from the server's others, so waiting prompts can't keep
/// notices out, and what a prompt shows is never logged or written anywhere.
final class PermissionGate: @unchecked Sendable {
    static let maxPending = 16
    static let maxBodyBytes = 262_144
    /// Shorter than the hook's own `timeout` of 600 s and curl's `-m 590`, so the server lets go first.
    static let holdSeconds = 585.0
    /// Nonces remembered for refusing a replay. Only a request with a valid proof adds one.
    private static let rememberedNonces = 4096

    /// Whether prompts are taken at all; off, the hook gets nothing and the terminal asks as usual.
    var isEnabled: @Sendable () -> Bool = { true }
    var onPrompt: (@MainActor (PermissionPrompt) -> Void)?
    /// The hook of this prompt is gone without an answer from the notch.
    var onGone: (@MainActor (UUID) -> Void)?

    private struct Held {
        let connection: NWConnection
        let nonce: String
        let suggestion: [String: Any]?
        let timeout: DispatchWorkItem
    }

    private let token: String
    private let queue: DispatchQueue
    private let holdSeconds: Double
    private var held: [UUID: Held] = [:]
    private var nonces: [String] = []
    private var knownNonces = Set<String>()

    init(token: String, queue: DispatchQueue, holdSeconds: Double = PermissionGate.holdSeconds) {
        self.token = token
        self.queue = queue
        self.holdSeconds = holdSeconds
    }

    func holds(_ connection: NWConnection) -> Bool {
        held.values.contains { $0.connection === connection }
    }

    /// Takes a `/permission` request; true when its connection is now held for an answer.
    func accept(_ request: NotifyServer.Request, on connection: NWConnection) -> Bool {
        guard request.method == "POST", isEnabled() else {
            NotifyServer.reply(connection, status: "404 Not Found")
            return false
        }
        guard let nonce = request.headers["x-nonce"], PermissionWire.isNonce(nonce),
              NotifyServer.constantTimeEqual(request.headers["x-proof"] ?? "",
                                             PermissionWire.requestProof(token: token, nonce: nonce, body: request.body)),
              remember(nonce) else {
            NotifyServer.reply(connection, status: "401 Unauthorized")
            return false
        }
        guard held.count < Self.maxPending else {
            NotifyServer.reply(connection, status: "503 Service Unavailable")
            return false
        }
        guard let parsed = PermissionPrompt.parse(request.body) else {
            NotifyServer.reply(connection, status: "204 No Content")
            return false
        }
        let prompt = parsed.prompt
        let timeout = DispatchWorkItem { [weak self] in self?.release(prompt.id) }
        held[prompt.id] = Held(connection: connection, nonce: nonce, suggestion: parsed.suggestion, timeout: timeout)
        queue.asyncAfter(deadline: .now() + holdSeconds, execute: timeout)
        watch(connection, prompt.id)
        let handler = onPrompt
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(prompt) } }
        return true
    }

    /// Sends the user's answer to the hook that is waiting, if it still is.
    func answer(_ id: UUID, _ answer: PermissionAnswer) {
        queue.async { [self] in
            guard let entry = held.removeValue(forKey: id) else { return }
            entry.timeout.cancel()
            guard let decision = PermissionWire.decision(answer, suggestion: entry.suggestion) else {
                entry.connection.cancel()
                return
            }
            let proof = PermissionWire.responseProof(token: token, nonce: entry.nonce, decision: decision)
            NotifyServer.reply(entry.connection, status: "200 OK", body: Data("\(proof) ".utf8) + decision)
        }
    }

    /// Lets every waiting hook go without an answer.
    func cancelAll() {
        queue.async { [self] in releaseAll() }
    }

    /// On the queue.
    func releaseAll() {
        for id in Array(held.keys) { release(id) }
    }

    private func remember(_ nonce: String) -> Bool {
        guard knownNonces.insert(nonce).inserted else { return false }
        nonces.append(nonce)
        if nonces.count > Self.rememberedNonces { knownNonces.remove(nonces.removeFirst()) }
        return true
    }

    /// The hook closes its end when it is killed, and then the prompt has no one to answer.
    private func watch(_ connection: NWConnection, _ id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { release(id) } else { watch(connection, id) }
        }
    }

    private func release(_ id: UUID) {
        guard let entry = held.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.connection.cancel()
        let handler = onGone
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(id) } }
    }
}
