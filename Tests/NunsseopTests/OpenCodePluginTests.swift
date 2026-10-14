import Darwin
import Foundation
import Testing
@testable import Nunsseop

struct OpenCodePluginTextTests {
    @Test func theTextOfThePluginIsPinned() {
        #expect(Golden.matches(OpenCodePlugin.source(), named: "opencode-plugin.js"), "UPDATE_GOLDENS=1 rewrites")
        #expect(NotifyIntegration.openCodePlugin == OpenCodePlugin.source())
        #expect(OpenCodePlugin.source(port: 1234).contains("const PORT = 1234"))
    }

    @Test func thePluginHoldsNoSecretAndStartsNothing() {
        let text = OpenCodePlugin.source()
        #expect(text.hasPrefix("// Added by Nunsseop"))
        for spawning in ["child_process", "spawn", "exec(", "Bun.$", "Bun.spawn", "eval(", "new Function", "writeFile"] { #expect(!text.contains(spawning), "\(spawning)") }
        // The files are read when they are needed, and only the three of Nunsseop's folder.
        for secret in ["notify-token", "permission-key"] { #expect(text.contains("read(\"\(secret)\")"), "\(secret)") }
        #expect(text.components(separatedBy: "read(\"").count - 1 == 3)
        // Only the loopback address, with the proof of the permission key on the one request that asks.
        #expect(text.components(separatedBy: "http://127.0.0.1:${PORT}").count - 1 == 3)
        #expect(text.contains("MAX_BODY = \(PermissionGate.maxBodyBytes)") && text.contains("590000"))
    }

    @Test func theSameFileStillNoticesAFinishedSessionAndKeepsTheOldNoticeBody() {
        let text = OpenCodePlugin.source()
        #expect(text.contains("title: \"OpenCode\", message: \"Finished\", app: process.env.__CFBundleIdentifier"))
        #expect(text.contains("Authorization: `Bearer ${token}`"))
    }
}

/// A free loopback port, for a stand-in server of the tests' own.
private func freePort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                              sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    return UInt16(bigEndian: address.sin_port)
}

/// The notices the server was sent.
final class NoticeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NotifyServer.Notice] = []
    var notices: [NotifyServer.Notice] { lock.withLock { stored } }
    func add(_ notice: NotifyServer.Notice) { lock.withLock { stored.append(notice) } }
}

/// The real plugin run by node against the real server.
@MainActor
struct OpenCodePluginRunTests {
    private static let imports = "import { NunsseopPlugin } from \"./nunsseop.mjs\"\n"

    private func start(_ server: PermissionTestServer, body: String, port: UInt16? = nil, environment: [String: String] = [:]) throws
        -> (script: NodeScript, events: AgentEventLog, notices: NoticeRecorder) {
        let events = AgentEventLog(), notices = NoticeRecorder()
        server.server.onAgent = { events.add($0) }
        server.server.onNotify = { notices.add($0) }
        let script = try NodeScript(files: ["nunsseop.mjs": OpenCodePlugin.source(port: port ?? server.port)],
                                    main: Self.imports + NodeScript.prelude + body, home: server.home.url, environment: environment)
        return (script, events, notices)
    }

    private static let setUp = """
        const replies = []
        const client = { permission: { reply: async (reply) => { replies.push(reply) } } }
        const plugin = await NunsseopPlugin({ client, directory: "/Users/me/proj" })
        const event = (type, properties) => plugin.event({ event: { type, properties } })
        const request = (id) => ({ id, sessionID: "ses_main1", permission: "bash", patterns: ["npm run build"], metadata: {}, always: ["npm run *"],
                                   tool: { messageID: "msg_1", callID: "call_1" } })

        """

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func sessionsReachTheCountWithTheirStatesAndSubagentsDoNot() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (script, events, notices) = try start(server, body: Self.setUp + """
            await event("session.created", { info: { id: "ses_main1" } })
            await event("session.created", { info: { id: "ses_child1", parentID: "ses_main1" } })
            await event("session.status", { sessionID: "ses_main1", status: { type: "busy" } })
            await event("session.status", { sessionID: "ses_main1", status: { type: "busy" } })
            await event("session.status", { sessionID: "ses_child1", status: { type: "busy" } })
            await event("question.asked", { id: "q1", sessionID: "ses_main1", questions: [] })
            await event("question.replied", { sessionID: "ses_main1", requestID: "q1", answers: [] })
            await event("session.status", { sessionID: "ses_main1", status: { type: "retry", attempt: 1, message: "x", next: 1 } })
            await event("session.status", { sessionID: "ses_main1", status: { type: "idle" } })
            await event("session.idle", { sessionID: "ses_main1" })
            await event("session.status", { sessionID: "ses_child1", status: { type: "idle" } })
            await event("session.deleted", { sessionID: "ses_main1", info: { id: "ses_main1" } })
            await sleep(300)
            out({ done: true })
            """, environment: ["__CFBundleIdentifier": "com.apple.Terminal"])
        let result = try #require(await script.finish())
        #expect(result.status == 0 && result.lines.count == 1)
        await eventually { events.events.count >= 6 && notices.notices.count >= 1 }
        // A retry is still work, a repeat of a state is not sent again, and the session going idle twice finishes once.
        #expect(events.events.map(\.action) == [.opened, .working, .needsInput, .working, .finished, .remove])
        #expect(events.events.allSatisfy { $0.session == "ses_main1" && $0.agent == .opencode && $0.app == "com.apple.Terminal" })
        #expect(events.events.allSatisfy { $0.pid == script.process.process.processIdentifier })
        #expect(notices.notices.map(\.title) == ["OpenCode"] && notices.notices.first?.message == "Finished")
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func aPermissionIsAnsweredThroughTheClientAsOnceOrReject() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        for answer in [PermissionAnswer.allow, .deny] {
            let before = server.events.prompts.count
            let (script, _, _) = try start(server, body: Self.setUp + """
                await event("permission.asked", request("per_\(answer == .allow ? 1 : 2)"))
                await until(() => replies.length > 0)
                await sleep(100)
                out({ replies })
                """)
            await eventually { server.events.prompts.count == before + 1 }
            let prompt = try #require(server.events.prompts.last)
            #expect(prompt.tag == "OpenCode" && prompt.title == "Run a command" && prompt.detail == "npm run build" && prompt.folder == "proj")
            server.server.permissions.answer(prompt.id, answer)
            let result = try #require(await script.finish())
            let replies = try #require(result.lines.first?["replies"] as? [[String: Any]])
            #expect(replies.count == 1)
            #expect(replies.first?["requestID"] as? String == "per_\(answer == .allow ? 1 : 2)")
            #expect(replies.first?["reply"] as? String == (answer == .allow ? "once" : "reject"))
            #expect(replies.first?["message"] as? String == (answer == .deny ? "Denied in Nunsseop" : nil))
        }
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func anOlderClientIsAnsweredWithItsOwnCall() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (script, _, _) = try start(server, body: """
            const replies = []
            const client = { postSessionIdPermissionsPermissionId: async (call) => { replies.push(call) } }
            const plugin = await NunsseopPlugin({ client, directory: "/Users/me/proj" })
            await plugin.event({ event: { type: "permission.updated", properties: { id: "per_3", sessionID: "ses_main1", type: "edit", pattern: ["a.txt"],
                                                                              title: "Edit a.txt", metadata: { filepath: "/Users/me/proj/a.txt" }, time: { created: 1 } } } })
            await until(() => replies.length > 0)
            await sleep(100)
            out({ replies })
            """)
        await eventually { server.events.prompts.count == 1 }
        let prompt = try #require(server.events.prompts.first)
        #expect(prompt.title == "Edit a file" && prompt.detail == "a.txt" && prompt.secondary == "filepath: /Users/me/proj/a.txt\ntitle: Edit a.txt")
        server.server.permissions.answer(prompt.id, .allow)
        let result = try #require(await script.finish())
        let call = try #require((result.lines.first?["replies"] as? [[String: Any]])?.first)
        #expect((call["path"] as? [String: String]) == ["id": "ses_main1", "permissionID": "per_3"])
        #expect((call["body"] as? [String: String]) == ["response": "once"])
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func answeringInTheTerminalLeavesTheTerminalInChargeAndTakesTheCardDown() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        // "Answer in terminal" in the notch: no reply of the plugin's own.
        let (first, _, _) = try start(server, body: Self.setUp + """
            await event("permission.asked", request("per_4"))
            await gate("answered")
            await sleep(1500)
            out({ replies })
            """)
        await eventually { server.events.prompts.count == 1 }
        server.server.permissions.answer(try #require(server.events.prompts.last).id, .terminal)
        first.open("answered")
        #expect((try #require(await first.finish()).lines.first?["replies"] as? [Any])?.isEmpty == true)
        // Answered in OpenCode first: the plugin hears of it and drops its request, which takes the card down.
        let (second, _, _) = try start(server, body: Self.setUp + """
            await event("permission.asked", request("per_5"))
            await gate("shown")
            await event("permission.replied", { sessionID: "ses_main1", requestID: "per_5", reply: "once" })
            await sleep(500)
            out({ replies })
            """)
        await eventually { server.events.prompts.count == 2 }
        second.open("shown")
        await eventually { server.events.goneIDs.count == 1 }
        #expect(server.events.prompts.count == 2 && server.events.goneIDs == [server.events.prompts[1].id])
        #expect((try #require(await second.finish()).lines.first?["replies"] as? [Any])?.isEmpty == true)
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func thePermissionAskHookSetsTheStatusAndTheSameRequestIsNotAskedTwice() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        var statuses: [String] = []
        for (index, answer) in [PermissionAnswer.allow, .deny, .terminal].enumerated() {
            let (script, _, _) = try start(server, body: Self.setUp + """
                const output = { status: "ask" }
                await plugin["permission.ask"]({ id: "per_h\(index)", type: "bash", pattern: "npm test", sessionID: "ses_main1", messageID: "msg_1",
                                                 title: "Run npm test", metadata: {}, time: { created: 1 } }, output)
                // The event for the same request that follows is not asked again.
                await event("permission.updated", { id: "per_h\(index)", sessionID: "ses_main1", type: "bash", pattern: "npm test", metadata: {} })
                await sleep(300)
                out({ status: output.status, replies })
                """)
            await eventually { server.events.prompts.count == index + 1 }
            let prompt = try #require(server.events.prompts.last)
            #expect(prompt.title == "Run a command" && prompt.detail == "npm test")
            server.server.permissions.answer(prompt.id, answer)
            let result = try #require(await script.finish())
            statuses.append(result.lines.first?["status"] as? String ?? "?")
            #expect((result.lines.first?["replies"] as? [Any])?.isEmpty == true)
            #expect(server.events.prompts.count == index + 1)
        }
        #expect(statuses == ["allow", "deny", "ask"])
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func withoutAKeyOrAServerOrWithAHugeRequestTheTerminalKeepsAsking() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let hook = Self.setUp + """
            const output = { status: "ask" }
            const started = Date.now()
            await plugin["permission.ask"]({ id: "per_x", type: "bash", pattern: [HUGE], sessionID: "ses_main1", metadata: {} }, output)
            out({ status: output.status, quick: Date.now() - started < 5000 })
            """
        // No key file.
        try FileManager.default.removeItem(at: server.home.permissionKeyFile.deletingLastPathComponent().appendingPathComponent("permission-key"))
        let (noKey, _, _) = try start(server, body: hook.replacingOccurrences(of: "[HUGE]", with: "\"npm test\""))
        let first = try #require(await noKey.finish())
        #expect(first.lines.first?["status"] as? String == "ask" && first.lines.first?["quick"] as? Bool == true)
        // A key but nothing listening.
        let live = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (noServer, _, _) = try start(live, body: hook.replacingOccurrences(of: "[HUGE]", with: "\"npm test\""), port: 1)
        let second = try #require(await noServer.finish())
        #expect(second.lines.first?["status"] as? String == "ask" && second.lines.first?["quick"] as? Bool == true)
        // More than the server takes: not sent, so no card.
        let (huge, _, _) = try start(live, body: hook.replacingOccurrences(of: "[HUGE]", with: "\"x\".repeat(300000)"))
        let third = try #require(await huge.finish())
        #expect(third.lines.first?["status"] as? String == "ask")
        #expect(live.events.prompts.isEmpty && server.events.prompts.isEmpty)
    }

    /// A stand-in for Nunsseop's server, written in node with its own HMAC code: it checks the plugin's proof and answers with its own, so
    /// each side is checked against an implementation that isn't its own.
    private func standIn(port: UInt16, reply: String) -> String {
        """
        import http from "node:http"
        import { createHmac, createHash } from "node:crypto"
        import { readFileSync } from "node:fs"
        import { homedir } from "node:os"
        const key = readFileSync(`${homedir()}/Library/Application Support/Nunsseop/permission-key`, "utf8").replace(/[ \\t\\r\\n]/g, "")
        const sha = (text) => createHash("sha256").update(text).digest("hex")
        const mac = (domain, nonce, text) => createHmac("sha256", key).update(`${domain}\\n${nonce}\\n${sha(text)}`).digest("hex")
        const seen = []
        const server = http.createServer((request, response) => {
          let body = ""
          request.on("data", (chunk) => { body += chunk })
          request.on("end", () => {
            const nonce = request.headers["x-nonce"]
            const proof = request.headers["x-proof"]
            const decision = JSON.stringify({ behavior: "\(reply)" })
            const good = mac("nunsseop-permission-response", nonce, decision)
            seen.push({ nonce, proof, body, key, decision, good, requestProofOK: proof === mac("nunsseop-permission-request", nonce, body) })
            response.writeHead(200)
            response.end(`${"\(reply)" === "forged" ? "0".repeat(64) : good} ${decision}`)
          })
        })
        await new Promise((resolve) => {
          server.once("error", (error) => { out({ listenError: error.code }); process.exit(3) })
          server.listen(\(port), "127.0.0.1", resolve)
        })

        """
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func theProofsAreTheOnesSwiftComputesAndAnswerWithoutAValidProofIsRefused() async throws {
        for (reply, expected) in [("allow", "allow"), ("deny", "deny"), ("bogus", "ask"), ("forged", "ask")] {
            let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
            // A port let go of is anyone's: another process can take this one before the stand-in listens on it, and then the stand-in
            // says so and ends, and the test takes another.
            var attempt = 0
            var finished: (lines: [[String: Any]], status: Int32)?
            repeat {
                let port = freePort()
                let (script, _, _) = try start(server, body: standIn(port: port, reply: reply) + Self.setUp + """
                    const output = { status: "ask" }
                    await plugin["permission.ask"]({ id: "per_c", type: "edit", pattern: ["a.txt"], sessionID: "ses_main1", metadata: {} }, output)
                    server.close()
                    out({ status: output.status, seen })
                    """, port: port)
                finished = await script.finish()
                attempt += 1
            } while finished?.lines.first?["listenError"] != nil && attempt < 10
            let result = try #require(finished)
            #expect(result.lines.first?["status"] as? String == expected, "\(reply): the script printed \(result.lines) and ended with \(result.status)")
            let seen = try #require((result.lines.first?["seen"] as? [[String: Any]])?.first)
            let key = try #require(seen["key"] as? String), nonce = try #require(seen["nonce"] as? String)
            let body = Data(try #require(seen["body"] as? String).utf8)
            // The stand-in's code agrees with the plugin's, and Swift's agrees with both.
            #expect(seen["requestProofOK"] as? Bool == true)
            #expect(seen["proof"] as? String == PermissionWire.requestProof(key: key, nonce: nonce, body: body))
            #expect(seen["good"] as? String == PermissionWire.responseProof(key: key, nonce: nonce, decision: Data(try #require(seen["decision"] as? String).utf8)))
            #expect(key == server.permissionKey && PermissionWire.isNonce(nonce))
        }
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func aKeyFileWithAnEndingNewlineStillProves() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let file = server.home.permissionKeyFile.deletingLastPathComponent().appendingPathComponent("permission-key")
        try Data((server.permissionKey + " \n").utf8).write(to: file)
        let (script, _, _) = try start(server, body: Self.setUp + """
            const output = { status: "ask" }
            await plugin["permission.ask"]({ id: "per_n", type: "bash", pattern: "ls", sessionID: "ses_main1", metadata: {} }, output)
            out({ status: output.status })
            """)
        await eventually { server.events.prompts.count == 1 }
        server.server.permissions.answer(try #require(server.events.prompts.first).id, .allow)
        #expect(try #require(await script.finish()).lines.first?["status"] as? String == "allow")
    }
}
