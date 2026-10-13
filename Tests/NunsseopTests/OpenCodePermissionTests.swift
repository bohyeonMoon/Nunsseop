import Foundation
import Testing
@testable import Nunsseop

/// What the OpenCode plugin sends for a permission request, as the server parses it into a card.
enum OpenCodeBody {
    static func make(permission: String = "bash", patterns: Any = ["npm run build"], metadata: [String: Any] = [:], title: String? = nil,
                     cwd: String = "/Users/me/proj", session: String = "ses_abc123", agent: String? = "opencode",
                     extra: [String: Any] = [:]) -> Data {
        var input: [String: Any] = ["patterns": patterns, "metadata": metadata]
        input["title"] = title
        var json: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session, "cwd": cwd, "tool_name": permission, "tool_input": input]
        json["agent"] = agent
        return try! JSONSerialization.data(withJSONObject: json.merging(extra) { $1 })
    }
}

struct OpenCodePermissionParseTests {
    private func prompt(_ body: Data) throws -> PermissionPrompt { try #require(PermissionPrompt.parse(body)).prompt }

    @Test func aCommandShowsItsPatternsAsAnOpenCodeCardWithoutAlwaysAllow() throws {
        let parsed = try #require(PermissionPrompt.parse(OpenCodeBody.make(extra: ["permission_suggestions": [PermissionTestServer.addRules]])))
        let card = parsed.prompt
        #expect(card.title == "Run a command" && card.symbol == "terminal" && card.detail == "npm run build" && card.folder == "proj")
        #expect(card.tag == "OpenCode" && !card.isCodex && card.grant == nil && card.secondary.isEmpty && card.flags.isEmpty)
        #expect(parsed.openCode && parsed.suggestion == nil && parsed.questionInput == nil)
        // The card has the third button, and it is "Answer in terminal".
        #expect(PermissionLayout.hasThirdButton(card, .card) && PermissionLayout.hasThirdButton(card, .panel))
    }

    @Test func theKnownPermissionsAreSaidInPlainWords() throws {
        let titles: [(String, String, String)] = [
            ("bash", "Run a command", "terminal"), ("edit", "Edit a file", "pencil"), ("read", "Read a file", "doc.text"),
            ("webfetch", "Fetch a web page", "globe"), ("websearch", "Search the web", "magnifyingglass"),
            ("external_directory", "Use files outside the project", "folder")]
        for (permission, title, symbol) in titles {
            let card = try prompt(OpenCodeBody.make(permission: permission))
            #expect(card.title == title && card.symbol == symbol, "\(permission)")
        }
        // Any other permission is its own name, with every field shown.
        let other = try prompt(OpenCodeBody.make(permission: "my_tool", patterns: ["a", "b"], metadata: ["n": 3]))
        #expect(other.title == "my_tool" && other.symbol == "puzzlepiece.extension" && other.detail == "a\nb" && other.secondary == "n: 3")
    }

    @Test func anEditShowsItsFileAndDiffAndAFetchItsAddress() throws {
        let edit = try prompt(OpenCodeBody.make(permission: "edit", patterns: ["src/main.swift"],
                                                metadata: ["filepath": "/Users/me/proj/src/main.swift", "diff": "-old\n+new"]))
        #expect(edit.detail == "src/main.swift" && edit.secondary == "diff: -old\n+new\nfilepath: /Users/me/proj/src/main.swift")
        let fetch = try prompt(OpenCodeBody.make(permission: "webfetch", patterns: ["https://example.com/x"],
                                                 metadata: ["url": "https://example.com/x", "format": "markdown", "timeout": 30]))
        #expect(fetch.detail == "https://example.com/x" && fetch.secondary == "format: markdown\ntimeout: 30\nurl: https://example.com/x")
    }

    @Test func theTitleOlderVersionsSendIsListedWithTheRest() throws {
        let card = try prompt(OpenCodeBody.make(patterns: "npm test", metadata: ["cwd": "/x"], title: "Run npm test"))
        // v1 gave one pattern as a string.
        #expect(card.detail == "" && card.secondary == "cwd: /x\ntitle: Run npm test")
        let list = try prompt(OpenCodeBody.make(patterns: ["npm test", 5, "ls"]))
        #expect(list.detail == "npm test\nls")
    }

    @Test func aBodyThatDoesntSayOpenCodeIsTreatedAsClaudeCodes() throws {
        let plain = try prompt(OpenCodeBody.make(agent: nil))
        #expect(plain.tag == nil && plain.title == "bash" && !plain.isCodex)
        let other = try prompt(OpenCodeBody.make(agent: "codex"))
        #expect(other.tag == nil)
    }

    @Test func whatCantBeShownWholeIsLeftToTheTerminal() throws {
        let huge = String(repeating: "x", count: PermissionPrompt.detailLimit + 1)
        #expect(PermissionPrompt.parse(OpenCodeBody.make(patterns: [huge])) == nil)
        #expect(PermissionPrompt.parse(OpenCodeBody.make(permission: "")) == nil)
        // Odd characters are said, as for any tool.
        let tricky = try prompt(OpenCodeBody.make(patterns: ["rm \u{202E}-rf"]))
        #expect(tricky.detail.contains("⟨U+202E⟩"))
    }

    @Test func theCardNamesTheToolBeforeTheTitle() {
        let narrow = PermissionLayout.titleFits(String(repeating: "m", count: 40), folder: "proj")
        let withTag = PermissionLayout.titleFits(String(repeating: "m", count: 40), folder: "proj", tag: "OpenCode")
        let codex = PermissionLayout.titleFits(String(repeating: "m", count: 40), folder: "proj", codex: true)
        #expect(narrow || !withTag)
        // A longer label takes more of the row than Codex's.
        let longest = { (tag: String?, codex: Bool) in
            (1...200).last { PermissionLayout.titleFits(String(repeating: "m", count: $0), folder: "proj", codex: codex, tag: tag) } ?? 0
        }
        #expect(longest("OpenCode", false) < longest(nil, true) && longest(nil, true) < longest(nil, false))
        #expect(codex == PermissionLayout.titleFits(String(repeating: "m", count: 40), folder: "proj", tag: "Codex"))
    }

    @Test func onlyAllowAndDenyAreAnswersTheOpenCodePluginReads() throws {
        func behavior(_ answer: PermissionAnswer) throws -> String? {
            try PermissionWire.decision(answer, suggestion: nil, openCode: true).map {
                (try JSONSerialization.jsonObject(with: $0) as? [String: Any])?["behavior"] as? String ?? "?"
            }
        }
        #expect(try behavior(.allow) == "allow" && behavior(.deny) == "deny")
        #expect(try behavior(.always) == nil && behavior(.terminal) == nil && behavior(.answered([0: [0]])) == nil)
        #expect(PermissionWire.decision(.allow, suggestion: nil, openCode: true) == Data(#"{"behavior":"allow"}"#.utf8))
        // Claude Code's answer is unchanged.
        #expect(String(decoding: PermissionWire.decision(.allow, suggestion: nil) ?? Data(), as: UTF8.self).contains("hookSpecificOutput"))
    }
}

@MainActor
struct OpenCodePermissionServerTests {
    private func answer(_ server: PermissionTestServer, to body: Data, nonce: String = PermissionTestServer.nonce(), proof: String? = nil) async throws
        -> (client: RawClient, nonce: String) {
        let client = try RawClient(port: server.port)
        client.send(server.request(body: body, nonce: nonce, proof: proof))
        return (client, nonce)
    }

    @Test func allowAndDenyAreAnsweredWithAProofOfTheNonceAndTheDecision() async throws {
        let server = try await PermissionTestServer()
        for decision in [PermissionAnswer.allow, .deny] {
            let before = server.events.prompts.count
            let (client, nonce) = try await answer(server, to: OpenCodeBody.make())
            await eventually { server.events.prompts.count == before + 1 }
            let prompt = try #require(server.events.prompts.last)
            #expect(prompt.tag == "OpenCode" && prompt.title == "Run a command")
            server.server.permissions.answer(prompt.id, decision)
            let text = String(decoding: await client.read(timeout: 5), as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 200 OK"))
            let reply = String(text.components(separatedBy: "\r\n\r\n").last ?? "")
            let space = try #require(reply.firstIndex(of: " "))
            let (proof, body) = (String(reply[..<space]), String(reply[reply.index(after: space)...]))
            #expect(body == #"{"behavior":"\#(decision == .allow ? "allow" : "deny")"}"#)
            #expect(proof == PermissionWire.responseProof(key: server.permissionKey, nonce: nonce, decision: Data(body.utf8)))
        }
    }

    @Test func aTerminalAnswerAndAnAlwaysAllowSayNothing() async throws {
        let server = try await PermissionTestServer()
        for decision in [PermissionAnswer.terminal, .always] {
            let before = server.events.prompts.count
            let (client, _) = try await answer(server, to: OpenCodeBody.make())
            await eventually { server.events.prompts.count == before + 1 }
            server.server.permissions.answer(try #require(server.events.prompts.last).id, decision)
            let text = String(decoding: await client.read(timeout: 5), as: UTF8.self)
            // Terminal: 204 and no body. Always has no decision to print, so the connection is dropped.
            #expect(decision == .terminal ? text.hasPrefix("HTTP/1.1 204") : !text.contains("behavior"))
        }
    }

    @Test func aRequestWithTheWrongProofShowsNoCard() async throws {
        let server = try await PermissionTestServer()
        let (client, _) = try await answer(server, to: OpenCodeBody.make(), proof: String(repeating: "0", count: 64))
        #expect(await client.status() == "HTTP/1.1 401 Unauthorized")
        let foreign = PermissionWire.requestProof(key: "another key that is long enough to be one", nonce: PermissionTestServer.nonce(), body: OpenCodeBody.make())
        let (second, _) = try await answer(server, to: OpenCodeBody.make(), proof: foreign)
        #expect(await second.status() == "HTTP/1.1 401 Unauthorized")
        #expect(server.events.prompts.isEmpty)
    }

    @Test func theCardGoesWhenOpenCodeGivesUpWaiting() async throws {
        let server = try await PermissionTestServer()
        let (client, _) = try await answer(server, to: OpenCodeBody.make())
        await eventually { server.events.prompts.count == 1 }
        client.close()
        await eventually { server.events.goneIDs.count == 1 }
        #expect(server.events.goneIDs == server.events.prompts.map(\.id))
    }
}
