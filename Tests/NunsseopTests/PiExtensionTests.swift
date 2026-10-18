import Foundation
import Testing
@testable import Nunsseop

struct PiExtensionTextTests {
    @Test func theTextOfEachToolsExtensionIsPinned() {
        for agent in [AgentKind.omp, .omo, .pi] {
            #expect(Golden.matches(PiExtension.source(agent: agent), named: "pi-extension-\(agent.rawValue).ts"), "\(agent) (UPDATE_GOLDENS=1 rewrites)")
        }
    }

    @Test func theExtensionsDifferOnlyInTheToolAndWhetherItSaysWhenATurnSettled() {
        let omp = PiExtension.source(agent: .omp), omo = PiExtension.source(agent: .omo), pi = PiExtension.source(agent: .pi)
        #expect(omp.contains("const AGENT = \"omp\"") && omo.contains("const AGENT = \"omo\"") && pi.contains("const AGENT = \"pi\""))
        #expect(omp.contains("const SETTLES = false") && omo.contains("const SETTLES = true") && pi.contains("const SETTLES = true"))
        #expect(omo.replacingOccurrences(of: "\"omo\"", with: "\"pi\"") == pi)
        #expect(PiExtension.source(agent: .omp, port: 1234).contains("const PORT = 1234"))
        #expect(omp.hasPrefix(PiExtension.marker))
    }

    @Test func theExtensionKeepsNoSecretAndStartsNothing() {
        let text = PiExtension.source(agent: .omo)
        // The token is read from the header file when an event is sent.
        #expect(text.contains("notify-auth") && !text.contains("notify-token") && !text.contains("permission-key") && !text.contains("Bearer"))
        for spawning in ["child_process", "spawn", "exec(", "execSync", "Bun.$", "Bun.spawn", "eval(", "new Function", "writeFile", "appendFile"] {
            #expect(!text.contains(spawning), "\(spawning)")
        }
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("import ") }.count == 3)
        // Only the loopback address, on the notify server's port.
        #expect(text.contains("host: \"127.0.0.1\"") && text.contains("const PORT = \(NotifyServer.port)") && !text.contains("fetch("))
    }
}

struct PiExtensionInstallTests {
    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func backup(of url: URL) -> URL { url.appendingPathExtension("nunsseop-backup") }
    private func folder(_ home: URL, _ tool: NotifyIntegration) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".\(tool.rawValue)/agent"), withIntermediateDirectories: true)
    }

    @Test func aToolIsOfferedOnlyWhereItHasBeenUsed() throws {
        try withTempHome { home in
            #expect(NotifyIntegration.allCases.filter(\.isPresent).isEmpty)
            try folder(home, .omo)
            #expect(NotifyIntegration.allCases.filter(\.isPresent) == [.omo])
            try folder(home, .omp)
            try folder(home, .pi)
            #expect(NotifyIntegration.allCases.filter(\.isPresent) == [.omp, .omo, .pi])
            #expect(NotifyIntegration.omp.name == "omp" && NotifyIntegration.omo.name == "omo" && NotifyIntegration.pi.name == "pi")
            #expect(NotifyIntegration.omp.configURL.path == home.appendingPathComponent(".omp/agent/extensions/nunsseop.ts").path)
            #expect(NotifyIntegration.pi.configURL.lastPathComponent == "nunsseop.ts")
            #expect(NotifyIntegration.omp.piAgent == .omp && NotifyIntegration.claudeCode.piAgent == nil && NotifyIntegration.openCode.piAgent == nil)
            // The settings row for a tool that isn't of ours is untouched by these.
            #expect(NotifyIntegration.reportingSessions.contains(.omp) && NotifyIntegration.reportingSessions.contains(.pi))
        }
    }

    @Test func connectingWritesTheExtensionOnceAndDisconnectingRemovesIt() throws {
        try withTempHome { home in
            try folder(home, .omp)
            let tool = NotifyIntegration.omp
            #expect(!tool.isInstalled)
            try tool.install()
            #expect(tool.isInstalled && text(tool.configURL) == PiExtension.source(agent: .omp))
            let written = try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date
            // Connected again, nothing is written and no backup is made.
            Thread.sleep(forTimeInterval: 0.02)
            try tool.install()
            #expect(try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date == written)
            #expect(!FileManager.default.fileExists(atPath: backup(of: tool.configURL).path))
            #expect(!NotifyIntegration.omo.isInstalled && !NotifyIntegration.pi.isInstalled)
            try tool.uninstall()
            #expect(!tool.isInstalled && !FileManager.default.fileExists(atPath: tool.configURL.path))
            try tool.uninstall()
        }
    }

    @Test func aFileOfTheSameNameThatIsNotOursIsKeptAsABackupAndNeverRemoved() throws {
        try withTempHome { home in
            let tool = NotifyIntegration.omo
            try folder(home, .omo)
            try FileManager.default.createDirectory(at: tool.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("// my own extension\n".utf8).write(to: tool.configURL)
            #expect(!tool.isInstalled)
            // Not ours: neither a refresh at launch nor Disconnect touches it.
            NotifyIntegration.updateConnectedNow()
            try tool.uninstall()
            #expect(text(tool.configURL) == "// my own extension\n")
            try tool.install()
            #expect(tool.isInstalled && text(backup(of: tool.configURL)) == "// my own extension\n")
            // An older version of ours is replaced without making that backup the older version.
            try Data((PiExtension.marker + ": an older version\n").utf8).write(to: tool.configURL)
            #expect(tool.isInstalled)
            NotifyIntegration.updateConnectedNow()
            #expect(text(tool.configURL) == PiExtension.source(agent: .omo) && text(backup(of: tool.configURL)) == "// my own extension\n")
        }
    }

    /// The file says "Delete this file to stop", not "edit me", but an edit that kept the first line is still a user's work.
    @Test func anExtensionEditedByHandIsKeptAsABackupBeforeItIsReplaced() throws {
        try withTempHome { home in
            let tool = NotifyIntegration.pi
            try folder(home, .pi)
            try tool.install()
            let edited = PiExtension.source(agent: .pi).replacingOccurrences(of: "timeout: 1000", with: "timeout: 5000")
            #expect(edited != PiExtension.source(agent: .pi))
            try Data(edited.utf8).write(to: tool.configURL)
            NotifyIntegration.updateConnectedNow()
            #expect(text(tool.configURL) == PiExtension.source(agent: .pi) && text(backup(of: tool.configURL)) == edited)
            // A later upgrade does not give up what is already kept.
            try Data((PiExtension.marker + ": an older version\n").utf8).write(to: tool.configURL)
            NotifyIntegration.updateConnectedNow()
            #expect(text(tool.configURL) == PiExtension.source(agent: .pi) && text(backup(of: tool.configURL)) == edited)
        }
    }

    @Test func launchBringsEachConnectedToolsExtensionUpToDateAndLeavesTheOthersAlone() throws {
        try withTempHome { home in
            for tool in [NotifyIntegration.omp, .pi] { try folder(home, tool) }
            try NotifyIntegration.omp.install()
            try Data((PiExtension.marker + " (old)\n").utf8).write(to: NotifyIntegration.omp.configURL)
            NotifyIntegration.updateConnectedNow()
            #expect(text(NotifyIntegration.omp.configURL) == PiExtension.source(agent: .omp))
            // pi was never connected, so nothing is put there.
            #expect(!FileManager.default.fileExists(atPath: NotifyIntegration.pi.configURL.path))
            #expect(!FileManager.default.fileExists(atPath: NotifyIntegration.omo.configURL.path))
        }
    }

    @Test func theOtherToolsAreConnectedAsBefore() throws {
        try withTempHome { home in
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
            try NotifyIntegration.openCode.install()
            #expect(NotifyIntegration.openCode.isInstalled && text(NotifyIntegration.openCode.configURL) == NotifyIntegration.openCodePlugin)
            NotifyIntegration.updateConnectedNow()
            #expect(NotifyIntegration.openCode.isInstalled)
            try NotifyIntegration.openCode.uninstall()
            #expect(!NotifyIntegration.openCode.isInstalled)
        }
    }
}

/// The real extension run by node, under `omp` and `omo` as they would call it, against the real server.
@MainActor
struct PiExtensionRunTests {
    private func extensionRun(_ server: PermissionTestServer, agent: AgentKind, body: String, environment: [String: String] = [:]) throws
        -> (script: NodeScript, events: AgentEventLog) {
        let log = AgentEventLog()
        server.server.onAgent = { log.add($0) }
        let script = try NodeScript(files: ["nunsseop.mjs": PiExtension.source(agent: agent, port: server.port)],
                                    main: NodeScript.prelude + Self.fakePi + body, home: server.home.url, environment: environment)
        return (script, log)
    }

    /// A stand-in for the tool's extension API: handlers by event name, and a context that is a main session in the terminal.
    private static let fakePi = """
        import extension from "./nunsseop.mjs"
        const handlers = {}
        const bus = {}
        const pi = { on: (name, handler) => { (handlers[name] ??= []).push(handler) }, events: { on: (name, handler) => { (bus[name] ??= []).push(handler) } } }
        extension(pi)
        const context = (extra = {}) => ({ mode: "tui", agent: { kind: "main" }, sessionManager: { getSessionId: () => "sess-1" }, isIdle: () => true, ...extra })
        const fire = (name, event = {}, ctx = context()) => (handlers[name] ?? []).forEach((handler) => handler(event, ctx))
        const block = (data) => (bus["herdr:blocked"] ?? []).forEach((handler) => handler(data))

        """

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func ompReportsATurnAfterASecondWithoutANewOneAndIsRemovedOnShutdown() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (script, log) = try extensionRun(server, agent: .omp, body: """
            fire("session_start")
            fire("agent_start")
            fire("agent_end", { messages: [] })
            await sleep(300)
            // Another turn starts before the second is over: the first one never finished.
            fire("agent_start")
            fire("agent_end", { messages: [] })
            await sleep(2500)
            fire("agent_start")
            fire("tool_approval_requested", { toolCallId: "t1", toolName: "bash" })
            fire("tool_approval_resolved", { toolCallId: "t1" })
            fire("session_shutdown", { })
            await sleep(300)
            out({ done: true })
            """, environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty", "HERDR_PANE_ID": "w1:p1"])
        let result = try #require(await script.finish())
        #expect(result.status == 0 && result.lines.count == 1)
        await eventually { log.events.count >= 8 }
        let events = log.events
        #expect(events.map(\.action) == [.opened, .working, .working, .finished, .working, .needsInput, .working, .remove])
        #expect(events.allSatisfy { $0.session == "sess-1" && $0.agent == .omp && $0.app == "com.mitchellh.ghostty" && $0.inHerdr })
        #expect(events.allSatisfy { $0.pid == script.process.process.processIdentifier })
    }

    /// omp's `agent_end` with `isTerminal: false` is a pause (retry backoff, compaction, a queued follow-up), not the end of the run.
    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func ompDoesNotFinishAtAnEndThatIsOnlyAPause() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (script, log) = try extensionRun(server, agent: .omp, body: """
            fire("session_start")
            fire("agent_start")
            fire("agent_end", { isTerminal: false, messages: [] })
            await sleep(1500)
            out({ paused: true })
            // The retry begins after more than a second: the same turn goes on.
            fire("agent_start")
            fire("agent_end", { isTerminal: true, messages: [] })
            await sleep(1500)
            out({ done: true })
            """)
        let result = try #require(await script.finish())
        #expect(result.status == 0 && result.lines.count == 2)
        await eventually { log.events.count >= 4 }
        #expect(log.events.map(\.action) == [.opened, .working, .working, .finished])
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func omoFinishesAtSettledNotAtTheEndOfAnAnswerAndReportsItsDialogs() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (script, log) = try extensionRun(server, agent: .omo, body: """
            fire("session_start")
            fire("agent_start")
            fire("agent_end", { messages: [] })
            await sleep(1300)
            block({ active: true, label: "Overwrite?", id: "d1" })
            block({ active: true, label: "Second", id: "d2" })
            block({ active: false, id: "d1" })
            block({ active: false, id: "d2" })
            fire("agent_settled")
            await sleep(100)
            // A dialog while idle ends in idle, not working.
            block({ active: true, label: "Pick one", id: "d3" })
            block({ active: false, id: "d3" })
            await sleep(300)
            out({ done: true })
            """)
        let result = try #require(await script.finish())
        #expect(result.status == 0)
        await eventually { log.events.count >= 7 }
        // The end of the answer alone says nothing; two dialogs are one hand; settling is the end.
        #expect(log.events.map(\.action) == [.opened, .working, .needsInput, .working, .finished, .needsInput, .idle])
        #expect(log.events.allSatisfy { $0.agent == .omo && !$0.inHerdr })
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func onlyTheMainSessionInTheTerminalIsReported() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (script, log) = try extensionRun(server, agent: .pi, body: """
            const sub = context({ agent: { kind: "sub", id: "0-Explore" } })
            const rpc = context({ mode: "rpc" })
            for (const ctx of [sub, rpc]) { fire("session_start", {}, ctx); fire("agent_start", {}, ctx); fire("agent_settled", {}, ctx) }
            await sleep(200)
            out({ before: true })
            fire("session_start")
            fire("agent_start")
            fire("agent_settled")
            await sleep(300)
            out({ done: true })
            """)
        let result = try #require(await script.finish())
        #expect(result.lines.count == 2)
        await eventually { log.events.count >= 3 }
        #expect(log.events.map(\.action) == [.opened, .working, .finished] && log.events.allSatisfy { $0.agent == .pi })
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func aReloadKeepsTheSessionAndATurnInProgressCountsAsWorking() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (script, log) = try extensionRun(server, agent: .omo, body: """
            fire("session_start", {}, context({ isIdle: () => false }))
            fire("session_shutdown", { reason: "reload" })
            await sleep(300)
            out({ done: true })
            """)
        _ = try #require(await script.finish())
        await eventually { log.events.count >= 2 }
        #expect(log.events.map(\.action) == [.opened, .working])
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func aMissingHeaderFileNoServerAndAHandlerThatThrowsCostTheToolNothing() async throws {
        // Port 1 has no server. One home has the header file, the other doesn't; neither makes the script fail or wait.
        for token in [String?.none, String(repeating: "t", count: 40)] {
            let home = try ScratchHome(token: token)
            let script = try NodeScript(files: ["nunsseop.mjs": PiExtension.source(agent: .omp, port: 1)],
                                        main: NodeScript.prelude + Self.fakePi + """
                                        fire("session_start")
                                        fire("agent_start", {}, { mode: "tui", sessionManager: { getSessionId: () => { throw new Error("x") } } })
                                        fire("agent_end", null)
                                        fire("session_shutdown", null)
                                        await sleep(200)
                                        out({ survived: true })
                                        """, home: home.url)
            let result = try #require(await script.finish())
            #expect(result.status == 0 && result.lines.first?["survived"] as? Bool == true, "token \(token ?? "none")")
        }
    }
}

/// The events the server was sent, in order.
final class AgentEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentEvent] = []
    var events: [AgentEvent] { lock.withLock { stored } }
    func add(_ event: AgentEvent) { lock.withLock { stored.append(event) } }
}
