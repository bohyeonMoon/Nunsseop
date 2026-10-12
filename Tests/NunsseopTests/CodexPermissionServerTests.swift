import Foundation
import Testing
@testable import Nunsseop

/// A Codex approval through the real hook, the server and the board's answers.
@MainActor
struct CodexPermissionServerTests {
    private typealias F = CodexFixtures

    private func hook(for server: PermissionTestServer, _ body: Data = F.body()) throws -> HookProcess {
        try HookProcess(command: server.hookCommand, home: server.home.url, stdin: body)
    }

    private func decision(_ answer: PermissionAnswer) -> String { F.text(PermissionWire.decision(answer, suggestion: nil)) }

    @Test func allowAndDenyReachCodexThroughTheRealHookAsItsDecisionFormat() async throws {
        let server = try await PermissionTestServer()
        for answer in [PermissionAnswer.allow, .deny] {
            let before = server.events.prompts.count
            let process = try hook(for: server)
            await eventually { server.events.prompts.count == before + 1 }
            let prompt = try #require(server.events.prompts.last)
            #expect(prompt.isCodex && prompt.title == "Run a command" && prompt.folder == "repo")
            server.server.permissions.answer(prompt.id, answer)
            let result = try #require(await process.finish())
            #expect(result.stdout == decision(answer) && result.status == 0, "\(answer)")
            let output = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
            let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
            let chosen = try #require(specific["decision"] as? [String: Any])
            #expect(specific["hookEventName"] as? String == "PermissionRequest")
            #expect(chosen["behavior"] as? String == (answer == .allow ? "allow" : "deny"))
            #expect(chosen["message"] as? String == (answer == .deny ? "Denied in Nunsseop" : nil))
            #expect(Set(chosen.keys).isSubset(of: ["behavior", "message"]))
        }
        #expect(server.events.goneIDs.isEmpty)
    }

    @Test func answeringInTheTerminalPrintsNothingSoCodexShowsItsOwnPrompt() async throws {
        let server = try await PermissionTestServer()
        let process = try hook(for: server)
        await eventually { server.events.prompts.count == 1 }
        server.server.permissions.answer(try #require(server.events.prompts.first).id, .terminal)
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0)
    }

    @Test func alwaysAllowHasNothingToSayForCodexAndLeavesItToTheTerminal() async throws {
        let server = try await PermissionTestServer()
        let process = try hook(for: server, F.body(extra: ["permission_suggestions": [PermissionTestServer.addRules]]))
        await eventually { server.events.prompts.count == 1 }
        let prompt = try #require(server.events.prompts.first)
        #expect(prompt.grant == nil)
        server.server.permissions.answer(prompt.id, .always)
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0)
    }

    @Test func anApplyPatchAndAnMCPCallAreHeldAndAnsweredToo() async throws {
        let server = try await PermissionTestServer()
        let bodies = [F.body(tool: "apply_patch", input: ["command": F.patch(["*** Add File: /Users/x/f.txt", "+hi"])]),
                      F.body(tool: "mcp__github__create_issue", input: ["title": "Bug"])]
        for (index, body) in bodies.enumerated() {
            let process = try hook(for: server, body)
            await eventually { server.events.prompts.count == index + 1 }
            let prompt = try #require(server.events.prompts.last)
            server.server.permissions.answer(prompt.id, .allow)
            let result = try #require(await process.finish())
            #expect(result.stdout == decision(.allow), "\(prompt.title)")
        }
        #expect(server.events.prompts.map(\.title) == ["Edit files", "mcp__github__create_issue"])
    }

    @Test func theAnswerCarriesAProofOfTheSameNonceAndTheExactDecision() async throws {
        let server = try await PermissionTestServer()
        let client = try RawClient(port: server.port)
        let nonce = PermissionTestServer.nonce()
        client.send(server.request(body: F.body(), nonce: nonce))
        await eventually { server.events.prompts.count == 1 }
        server.server.permissions.answer(try #require(server.events.prompts.first).id, .allow)
        let text = String(decoding: await client.read(timeout: 5), as: UTF8.self)
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        let space = try #require(body.firstIndex(of: " "))
        let (proof, answer) = (String(body[..<space]), String(body[body.index(after: space)...]))
        #expect(answer == decision(.allow))
        #expect(proof == PermissionWire.responseProof(key: server.permissionKey, nonce: nonce, decision: Data(answer.utf8)))
    }

    @Test func aCodexBodyNeedsTheSameProofAsAClaudeOne() async throws {
        let server = try await PermissionTestServer()
        let body = F.body()
        let client = try RawClient(port: server.port)
        client.send(server.request(body: body, proof: PermissionWire.requestProof(key: server.token, nonce: "x", body: body)))
        #expect(await client.status() == "HTTP/1.1 401 Unauthorized")
        #expect(server.events.prompts.isEmpty)
    }

    @Test func aHookKilledBecauseCodexAnsweredFirstTakesItsCardAway() async throws {
        let server = try await PermissionTestServer()
        let process = try hook(for: server)
        await eventually { server.events.prompts.count == 1 }
        let id = try #require(server.events.prompts.first?.id)
        process.terminate()
        await eventually { server.events.goneIDs.contains(id) }
        #expect(server.events.goneIDs == [id])
    }

    @Test func aDisabledServerLeavesCodexToItsOwnPrompt() async throws {
        let server = try await PermissionTestServer()
        server.server.permissions.isEnabled = { false }
        let process = try hook(for: server)
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0 && server.events.prompts.isEmpty)
    }
}
