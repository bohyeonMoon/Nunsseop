import Foundation
import Testing
@testable import Nunsseop

struct AmpPluginTextTests {
    @Test func theFileIsPinned() {
        #expect(Golden.matches(AmpPlugin.source(), named: "amp-plugin.ts"), "UPDATE_GOLDENS=1 rewrites")
    }

    @Test func thePluginKeepsNoSecretAndStartsNothing() {
        let text = AmpPlugin.source()
        #expect(text.hasPrefix(PiExtension.marker))
        #expect(text.contains("notify-auth") && !text.contains("notify-token") && !text.contains("permission-key") && !text.contains("Bearer"))
        for spawning in ["child_process", "spawn", "exec(", "execSync", "Bun.$", "Bun.spawn", "amp.$", "eval(", "new Function", "writeFile", "appendFile"] {
            #expect(!text.contains(spawning), "\(spawning)")
        }
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("import ") }.count == 2)
        // Only the loopback address, on the notify server's port.
        #expect(text.contains("http://127.0.0.1:${PORT}") && text.contains("const PORT = \(NotifyServer.port)") && AmpPlugin.source(port: 1234).contains("const PORT = 1234"))
        // The description of a plugin has to be a literal of at most 300 characters.
        #expect(text.contains("export const description = \"Shows Amp threads in the Nunsseop notch\""))
        // Amp's API gives no process for a thread, so none is named.
        #expect(!text.contains("X-Pid"))
    }
}

struct AmpInstallTests {
    private let tool = NotifyIntegration.amp
    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func backup(of url: URL) -> URL { url.appendingPathExtension("nunsseop-backup") }

    private func folder(_ home: URL) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/amp/plugins"), withIntermediateDirectories: true)
    }

    @Test func aToolIsOfferedOnlyWhereItHasBeenUsed() throws {
        try withTempHome { home in
            #expect(!tool.isPresent)
            try folder(home)
            #expect(tool.isPresent && tool.name == "Amp" && tool.agentKind == .amp)
            #expect(tool.configURL.path == home.appendingPathComponent(".config/amp/plugins/nunsseop.ts").path)
            #expect(NotifyIntegration.reportingSessions.contains(.amp) && NotifyIntegration.askingForPermission(present: [.amp]).isEmpty)
        }
    }

    @Test func connectingWritesThePluginOnceAndDisconnectingRemovesIt() throws {
        try withTempHome { home in
            try folder(home)
            let theirs = home.appendingPathComponent(".config/amp/plugins/theirs.ts")
            try Data("export default () => {}\n".utf8).write(to: theirs)
            try tool.install()
            #expect(tool.isInstalled && text(tool.configURL) == AmpPlugin.source() && text(theirs) == "export default () => {}\n")
            let written = try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date
            Thread.sleep(forTimeInterval: 0.02)
            try tool.install()
            #expect(try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date == written)
            #expect(!FileManager.default.fileExists(atPath: backup(of: tool.configURL).path))
            try tool.uninstall()
            #expect(!tool.isInstalled && !FileManager.default.fileExists(atPath: tool.configURL.path) && text(theirs) == "export default () => {}\n")
            try tool.uninstall()
        }
    }

    @Test func aFileOfTheSameNameThatIsNotOursIsKeptAndNeverRemoved() throws {
        try withTempHome { home in
            try folder(home)
            try Data("// my own plugin\n".utf8).write(to: tool.configURL)
            #expect(!tool.isInstalled)
            NotifyIntegration.updateConnectedNow()
            try tool.uninstall()
            #expect(text(tool.configURL) == "// my own plugin\n")
            try tool.install()
            #expect(tool.isInstalled && text(backup(of: tool.configURL)) == "// my own plugin\n")
            try Data((PiExtension.marker + ": an older version\n").utf8).write(to: tool.configURL)
            NotifyIntegration.updateConnectedNow()
            #expect(text(tool.configURL) == AmpPlugin.source() && text(backup(of: tool.configURL)) == "// my own plugin\n")
        }
    }
}

/// The real plugin run by node (Amp runs plugins in Bun; `NUNSSEOP_TEST_NODE` runs the same script under it), against the real server.
@MainActor
struct AmpRunTests {
    private static let fake = """
        import plugin, { description } from "./nunsseop.mjs"
        const handlers = {}
        let dispose
        const amp = { on: (name, handler) => { (handlers[name] ??= []).push(handler) }, onDispose: (fn) => { dispose = fn } }
        plugin(amp)
        const thread = { id: "T-0194c1a2-7b3d-7000-8c11-aaaaaaaaaaaa" }
        const fire = (name, event) => (handlers[name] ?? []).map((handler) => handler({ thread, ...event }))

        """

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func aThreadIsReportedAndEachWayAnAnswerEndsIsTold() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let events = AgentEventLog(), notices = ServerNotices()
        server.server.onAgent = { events.add($0) }
        server.server.onNotify = { notices.add($0) }
        let script = try NodeScript(files: ["nunsseop.mjs": AmpPlugin.source(port: server.port)], main: NodeScript.prelude + NodeScript.patience + Self.fake + """
            out({ description, returned: [fire("session.start", {}), fire("agent.start", { message: "secret", id: "m1" })].flat().map((value) => value ?? null) })
            fire("agent.end", { status: "done", messages: [], id: "m1" })
            fire("agent.start", {})
            fire("agent.end", { status: "cancelled" })
            fire("agent.start", {})
            fire("agent.end", { status: "error" })
            await dispose()
            out({ done: true })
            """, home: server.home.url, environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty"])
        let result = try #require(await script.finish())
        #expect(result.status == 0 && result.lines.count == 2)
        #expect(result.lines.first?["description"] as? String == "Shows Amp threads in the Nunsseop notch")
        // Nothing is returned, so what Amp does with a prompt or the end of an answer is never changed.
        #expect((result.lines.first?["returned"] as? [Any])?.allSatisfy { $0 is NSNull } == true)
        await eventually { events.events.count >= 8 && notices.notices.count >= 1 }
        #expect(events.events.map(\.action) == [.opened, .working, .finished, .working, .idle, .working, .finished, .remove])
        #expect(events.events.allSatisfy { $0.session == "T-0194c1a2-7b3d-7000-8c11-aaaaaaaaaaaa" && $0.agent == .amp && $0.app == "com.mitchellh.ghostty" && $0.pid == nil })
        #expect(notices.notices.map(\.title) == ["Amp"] && notices.notices.first?.message == "Finished")
    }

    /// A node whose first request takes longer than the plugin's own second, as on a busy machine, where the first `fetch` alone can: the
    /// event is still sent, and the ones after it are not out of order or missing for it.
    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func aFirstRequestSlowerThanThePluginsOwnWaitStillReachesTheServer() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let events = AgentEventLog()
        server.server.onAgent = { events.add($0) }
        let script = try NodeScript(files: ["nunsseop.mjs": AmpPlugin.source(port: server.port), "slow-first-fetch.cjs": """
            // The signal is made before fetch is called, so it has run for 1.3 seconds of its second when the request is begun.
            const real = globalThis.fetch
            let first = true
            globalThis.fetch = async (...args) => {
              if (first) { first = false; await new Promise((resolve) => setTimeout(resolve, 1300)) }
              return real(...args)
            }
            """], main: NodeScript.prelude + NodeScript.patience + Self.fake + """
            fire("session.start", {})
            fire("agent.start", { message: "secret", id: "m1" })
            await sleep(300)
            out({ done: true })
            """, home: server.home.url, environment: ["NODE_OPTIONS": "--require ./slow-first-fetch.cjs"])
        let result = try #require(await script.finish())
        #expect(result.status == 0 && result.lines.count == 1)
        await eventually { events.events.count >= 2 }
        #expect(events.events.map(\.action) == [.opened, .working])
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func aMissingHeaderFileNoServerAndAnOddEventCostAmpNothing() async throws {
        for token in [String?.none, String(repeating: "t", count: 40)] {
            let home = try ScratchHome(token: token)
            let script = try NodeScript(files: ["nunsseop.mjs": AmpPlugin.source(port: 1)], main: NodeScript.prelude + Self.fake + """
                fire("session.start", {})
                fire("agent.end", { status: undefined })
                handlers["agent.start"].forEach((handler) => handler(null))
                handlers["agent.end"].forEach((handler) => handler(undefined))
                await dispose()
                out({ survived: true })
                """, home: home.url)
            let result = try #require(await script.finish())
            #expect(result.status == 0 && result.lines.first?["survived"] as? Bool == true, "token \(token ?? "none")")
        }
    }

    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func anApiWithoutOnDisposeStillWorks() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let script = try NodeScript(files: ["nunsseop.mjs": AmpPlugin.source(port: server.port)], main: NodeScript.prelude + """
            import plugin from "./nunsseop.mjs"
            const handlers = {}
            plugin({ on: (name, handler) => { handlers[name] = handler } })
            out({ names: Object.keys(handlers).sort() })
            """, home: server.home.url)
        let result = try #require(await script.finish())
        #expect(result.lines.first?["names"] as? [String] == ["agent.end", "agent.start", "session.start"])
    }
}
