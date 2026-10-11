import Foundation
import Testing
@testable import Nunsseop

/// `POST /permission` against a listening server, with the real hook (`/bin/sh` and curl) or a plain socket as the client.
@MainActor
struct PermissionServerTests {
    private func decisionText(_ answer: PermissionAnswer, suggestion: [String: Any]? = nil) throws -> String {
        String(decoding: try #require(PermissionWire.decision(answer, suggestion: suggestion)), as: UTF8.self)
    }

    private func hook(for server: PermissionTestServer, _ input: Data) throws -> HookProcess {
        try HookProcess(command: server.hookCommand, home: server.home.url, stdin: input)
    }

    /// Splits an answer's body into its proof and the decision, as the hook does.
    private func parts(_ response: Data) -> (status: String, proof: String, decision: String) {
        let text = String(decoding: response, as: UTF8.self)
        let status = text.components(separatedBy: "\r\n").first ?? ""
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        guard let space = body.firstIndex(of: " ") else { return (status, body, "") }
        return (status, String(body[..<space]), String(body[body.index(after: space)...]))
    }

    // MARK: The round trip

    @Test func theUsersAnswerReachesClaudeCodeThroughTheRealHook() async throws {
        let server = try await PermissionTestServer()
        for answer in [PermissionAnswer.allow, .deny, .always] {
            let before = server.events.prompts.count
            let process = try hook(for: server, PermissionTestServer.hookInput(
                cwd: "/Users/me/my project", suggestions: [PermissionTestServer.setMode, PermissionTestServer.addRules]))
            await eventually { server.events.prompts.count == before + 1 }
            let prompt = try #require(server.events.prompts.last)
            #expect(prompt.title == "Run a command" && prompt.detail == "npm run build")
            #expect(prompt.folder == "my project" && prompt.rule == "Bash(npm run *)")
            server.server.permissions.answer(prompt.id, answer)
            let result = try #require(await process.finish())
            #expect(result.stdout == (try decisionText(answer, suggestion: PermissionTestServer.addRules)), "\(answer)")
            #expect(result.status == 0)
            #expect(!result.stdout.contains("setMode"))
        }
        #expect(server.events.goneIDs.isEmpty)
    }

    @Test func theAnswerCarriesAProofOfTheSameNonceAndTheExactDecision() async throws {
        let server = try await PermissionTestServer()
        let client = try RawClient(port: server.port)
        let nonce = PermissionTestServer.nonce()
        client.send(server.request(body: PermissionTestServer.hookInput(suggestions: [PermissionTestServer.addRules]), nonce: nonce))
        await eventually { server.events.prompts.count == 1 }
        server.server.permissions.answer(server.events.prompts[0].id, .always)
        let answer = parts(client.read(timeout: 5))
        #expect(answer.status == "HTTP/1.1 200 OK")
        #expect(answer.decision == (try decisionText(.always, suggestion: PermissionTestServer.addRules)))
        #expect(answer.proof == PermissionWire.responseProof(token: server.token, nonce: nonce, decision: Data(answer.decision.utf8)))
        #expect(answer.proof != PermissionWire.responseProof(token: server.token, nonce: PermissionTestServer.nonce(),
                                                              decision: Data(answer.decision.utf8)))
    }

    @Test func aPromptWithoutARuleCannotBeAnsweredAlways() async throws {
        let server = try await PermissionTestServer()
        let client = try RawClient(port: server.port)
        client.send(server.request(body: PermissionTestServer.hookInput(suggestions: [PermissionTestServer.setMode])))
        await eventually { server.events.prompts.count == 1 }
        let prompt = server.events.prompts[0]
        #expect(prompt.rule == nil)
        server.server.permissions.answer(prompt.id, .always)
        // Nothing allows more than was offered: the connection closes without an answer, and the terminal asks.
        #expect(client.read(timeout: 5).isEmpty)
    }

    // MARK: Who may ask

    @Test func aRequestWithoutAValidProofIsRefusedAndShowsNothing() async throws {
        let server = try await PermissionTestServer()
        let body = PermissionTestServer.hookInput()
        let nonce = PermissionTestServer.nonce()
        let good = PermissionWire.requestProof(token: server.token, nonce: nonce, body: body)
        let flipped = String(good.dropLast()) + (good.last == "0" ? "1" : "0")
        let attempts: [(String, Data)] = [
            ("a wrong proof", server.request(body: body, nonce: nonce, proof: flipped)),
            ("another token's proof", server.request(body: body, nonce: nonce,
                                                     proof: PermissionWire.requestProof(token: server.token + "0", nonce: nonce, body: body))),
            ("a proof of another body", server.request(body: body, nonce: nonce,
                                                       proof: PermissionWire.requestProof(token: server.token, nonce: nonce, body: body + [0x20]))),
            ("a proof of another nonce", server.request(body: body, nonce: nonce,
                                                        proof: PermissionWire.requestProof(token: server.token, nonce: PermissionTestServer.nonce(), body: body))),
            ("the response's domain", server.request(body: body, nonce: nonce,
                                                     proof: PermissionWire.responseProof(token: server.token, nonce: nonce, decision: body))),
            ("an empty proof", server.request(body: body, nonce: nonce, proof: "")),
            ("a bearer token", Data("POST /permission HTTP/1.1\r\nAuthorization: Bearer \(server.token)\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body),
            ("a nonce that is not hex", server.request(body: body, nonce: "zz" + String(nonce.dropFirst(2)),
                                                       proof: PermissionWire.requestProof(token: server.token, nonce: "zz" + String(nonce.dropFirst(2)), body: body))),
        ]
        for (name, request) in attempts {
            let client = try RawClient(port: server.port)
            client.send(request)
            #expect(client.status() == "HTTP/1.1 401 Unauthorized", Comment(rawValue: name))
        }
        #expect(server.events.prompts.isEmpty)
    }

    @Test func aRepeatedRequestIsRefusedEvenAfterItWasAnswered() async throws {
        let server = try await PermissionTestServer()
        let body = PermissionTestServer.hookInput()
        let request = server.request(body: body)
        let first = try RawClient(port: server.port)
        first.send(request)
        await eventually { server.events.prompts.count == 1 }

        let second = try RawClient(port: server.port)
        second.send(request)
        #expect(second.status() == "HTTP/1.1 401 Unauthorized")

        server.server.permissions.answer(server.events.prompts[0].id, .deny)
        #expect(parts(first.read(timeout: 5)).status == "HTTP/1.1 200 OK")
        let third = try RawClient(port: server.port)
        third.send(request)
        #expect(third.status() == "HTTP/1.1 401 Unauthorized")
        #expect(server.events.prompts.count == 1)
    }

    @Test func aServerWithTheFeatureOffTakesNoPromptAndAnotherMethodIsNotServed() async throws {
        let server = try await PermissionTestServer()
        let body = PermissionTestServer.hookInput()
        let get = try RawClient(port: server.port)
        get.send(server.request(body: body, method: "GET"))
        #expect(get.status() == "HTTP/1.1 404 Not Found")

        server.server.permissions.isEnabled = { false }
        let client = try RawClient(port: server.port)
        client.send(server.request(body: body))
        #expect(client.status() == "HTTP/1.1 404 Not Found")
        #expect(server.events.prompts.isEmpty)
    }

    @Test func questionsAndGarbageAreHandedBackToTheTerminal() async throws {
        let server = try await PermissionTestServer()
        for body in [PermissionTestServer.hookInput(tool: "AskUserQuestion", input: ["questions": []]), Data("not json".utf8)] {
            let client = try RawClient(port: server.port)
            client.send(server.request(body: body))
            #expect(client.status() == "HTTP/1.1 204 No Content")
        }
        let process = try hook(for: server, PermissionTestServer.hookInput(tool: "ExitPlanMode", input: ["plan": "x"]))
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0)
        #expect(server.events.prompts.isEmpty)
    }

    // MARK: When the hook goes away

    @Test func aHookKilledBecauseTheTerminalAnsweredTakesItsCardAwayAtOnce() async throws {
        let server = try await PermissionTestServer()
        let process = try hook(for: server, PermissionTestServer.hookInput())
        await eventually { server.events.prompts.count == 1 }
        let id = try #require(server.events.prompts.first?.id)
        #expect(server.events.goneIDs.isEmpty)
        process.terminate()
        await eventually { server.events.goneIDs.contains(id) }
        #expect(server.events.goneIDs == [id])
        // An answer that comes too late has nowhere to go and does no harm.
        server.server.permissions.answer(id, .allow)
    }

    @Test func aConnectionThatClosesTakesItsCardAway() async throws {
        let server = try await PermissionTestServer()
        let client = try RawClient(port: server.port)
        client.send(server.request(body: PermissionTestServer.hookInput()))
        await eventually { server.events.prompts.count == 1 }
        client.close()
        await eventually { !server.events.goneIDs.isEmpty }
        #expect(server.events.goneIDs == [server.events.prompts[0].id])
    }

    @Test func aPromptNobodyAnswersEndsBeforeTheHooksOwnTimeout() async throws {
        #expect(PermissionGate.holdSeconds < Double(JSONHook.permissionTimeout))
        let server = try await PermissionTestServer(hold: 0.5)
        let process = try hook(for: server, PermissionTestServer.hookInput())
        await eventually { server.events.prompts.count == 1 }
        await eventually { !server.events.goneIDs.isEmpty }
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0)
        #expect(server.events.goneIDs == [server.events.prompts[0].id])
    }

    @Test func stoppingTheServerOrTurningTheFeatureOffLetsEveryHookGo() async throws {
        let server = try await PermissionTestServer()
        let clients = try (0..<3).map { _ in try RawClient(port: server.port) }
        for client in clients { client.send(server.request(body: PermissionTestServer.hookInput())) }
        await eventually { server.events.prompts.count == 3 }
        server.server.permissions.cancelAll()
        await eventually { server.events.goneIDs.count == 3 }
        for client in clients { #expect(client.read(timeout: 5).isEmpty) }

        let again = try RawClient(port: server.port)
        again.send(server.request(body: PermissionTestServer.hookInput()))
        await eventually { server.events.prompts.count == 4 }
        server.server.stop()
        await eventually { server.events.goneIDs.count == 4 }
        #expect(again.read(timeout: 5).isEmpty)
    }

    @Test func aWaitingPromptIsNotDroppedAsAStalledClient() async throws {
        let server = try await PermissionTestServer()
        let client = try RawClient(port: server.port)
        client.send(server.request(body: PermissionTestServer.hookInput()))
        await eventually { server.events.prompts.count == 1 }
        // Other connections are dropped after 5 s of saying nothing; no condition marks the absence of that drop.
        try await Task.sleep(for: .seconds(6.5))
        #expect(server.events.goneIDs.isEmpty)
        server.server.permissions.answer(server.events.prompts[0].id, .allow)
        #expect(parts(client.read(timeout: 5)).status == "HTTP/1.1 200 OK")
    }

    // MARK: Limits

    private func body(ofSize size: Int) throws -> Data {
        var padding = size - PermissionTestServer.hookInput(input: ["command": ""]).count
        var command = String(repeating: "a", count: max(padding, 0))
        var data = PermissionTestServer.hookInput(input: ["command": command])
        // Escapes and multi-byte characters would change the size, so it is adjusted until it is exact.
        while data.count != size {
            padding += size - data.count
            command = String(repeating: "a", count: padding)
            data = PermissionTestServer.hookInput(input: ["command": command])
        }
        return data
    }

    @Test func aBodyUpToTheCapIsTakenAndOneByteMoreIsRefusedAtOnce() async throws {
        #expect(PermissionGate.maxBodyBytes == 256 * 1024)
        let server = try await PermissionTestServer()
        let exact = try RawClient(port: server.port)
        exact.send(server.request(body: try body(ofSize: PermissionGate.maxBodyBytes)))
        await eventually { server.events.prompts.count == 1 }
        #expect(server.events.prompts.count == 1)

        let over = try RawClient(port: server.port)
        over.send(server.request(body: try body(ofSize: PermissionGate.maxBodyBytes + 1)))
        #expect(over.status() == "HTTP/1.1 413 Payload Too Large")
        let huge = try RawClient(port: server.port)
        huge.send(Data("POST /permission HTTP/1.1\r\nContent-Length: 2000000000\r\n\r\n".utf8))
        #expect(huge.status() == "HTTP/1.1 413 Payload Too Large")
        #expect(server.events.prompts.count == 1)
    }

    @Test func noticesStillHaveTheSmallerCap() async throws {
        let server = try await PermissionTestServer()
        let client = try RawClient(port: server.port)
        client.send(Data("POST /notify HTTP/1.1\r\nContent-Length: \(NotifyServer.maxRequestBytes + 1)\r\n\r\n".utf8))
        #expect(client.status() == "HTTP/1.1 413 Payload Too Large")
    }

    @Test func onlyAFewPromptsWaitAtOnce() async throws {
        let server = try await PermissionTestServer()
        var clients: [RawClient] = []
        for _ in 0..<PermissionGate.maxPending {
            let client = try RawClient(port: server.port)
            client.send(server.request(body: PermissionTestServer.hookInput()))
            clients.append(client)
        }
        await eventually { server.events.prompts.count == PermissionGate.maxPending }
        let extra = try RawClient(port: server.port)
        extra.send(server.request(body: PermissionTestServer.hookInput()))
        #expect(extra.status() == "HTTP/1.1 503 Service Unavailable")
        #expect(server.events.prompts.count == PermissionGate.maxPending)

        // A place frees up when one is answered.
        server.server.permissions.answer(server.events.prompts[0].id, .deny)
        _ = clients[0].read(timeout: 5)
        let next = try RawClient(port: server.port)
        next.send(server.request(body: PermissionTestServer.hookInput()))
        await eventually { server.events.prompts.count == PermissionGate.maxPending + 1 }
        #expect(server.events.prompts.count == PermissionGate.maxPending + 1)
        withExtendedLifetime(clients) {}
    }

    @Test func waitingPromptsDoNotUseUpTheConnectionsNoticesNeed() async throws {
        let server = try await PermissionTestServer()
        var clients: [RawClient] = []
        // More than the eight connections the server allows at once.
        for _ in 0..<PermissionGate.maxPending {
            let client = try RawClient(port: server.port)
            client.send(server.request(body: PermissionTestServer.hookInput()))
            clients.append(client)
        }
        await eventually { server.events.prompts.count == PermissionGate.maxPending }
        for _ in 0..<12 {
            let notice = try RawClient(port: server.port)
            notice.send(Data("POST /notify HTTP/1.1\r\nAuthorization: Bearer \(server.token)\r\nContent-Length: 0\r\n\r\n".utf8))
            #expect(notice.status() == "HTTP/1.1 204 No Content")
        }
        withExtendedLifetime(clients) {}
    }
}
