import Foundation
import Testing
@testable import Nunsseop

struct HermesPluginTextTests {
    @Test func theFilesArePinned() {
        #expect(Golden.matches(HermesPlugin.source(), named: "hermes-plugin.py"), "UPDATE_GOLDENS=1 rewrites")
        #expect(Golden.matches(HermesPlugin.manifest, named: "hermes-plugin.yaml"), "UPDATE_GOLDENS=1 rewrites")
    }

    @Test func thePluginKeepsNoSecretAndStartsNothingButItsOwnThread() {
        let text = HermesPlugin.source()
        #expect(text.hasPrefix(HermesPlugin.marker) && HermesPlugin.manifest.hasPrefix(HermesPlugin.marker))
        // The token is read from the header file when an event is sent.
        #expect(text.contains("notify-auth") && !text.contains("notify-token") && !text.contains("permission-key") && !text.contains("Bearer"))
        for spawning in ["subprocess", "os.system", "os.popen", "exec(", "eval(", "__import__", "open(\"w", "'w'", "\"w\"", "socket"] {
            #expect(!text.contains(spawning), "\(spawning)")
        }
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("import ") }.map { $0.dropFirst(7) }
                == ["json", "os", "queue", "re", "threading", "urllib.request"])
        #expect(text.contains("http://127.0.0.1:%d%s") && text.contains("PORT = \(NotifyServer.port)") && HermesPlugin.source(port: 1234).contains("PORT = 1234"))
        #expect(HermesPlugin.manifest == "# Added by Nunsseop: shows this Hermes session in the notch. Delete this folder to stop.\nname: nunsseop\nversion: \"1.0\"\ndescription: Shows Hermes sessions in the Nunsseop notch\n")
    }

    @Test(.enabled(if: PythonTool.available, PythonTool.reason))
    func thePluginCompiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-hermes-\(UUID().uuidString.prefix(8)).py")
        try Data(HermesPlugin.source().utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = PythonTool.url
        process.arguments = ["-B", "-c", "import ast, sys; ast.parse(open(sys.argv[1]).read())", file.path]
        // Nothing of the runner's output or input is the compiler's.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

struct HermesEnabledTests {
    @Test func theEnabledListIsReadInItsUsualForms() {
        let block = "model:\n  default: x\nplugins:\n  enabled:\n    - orca-status\n    - \"nunsseop\"\n  disabled: []\nother: 1\n"
        #expect(HermesPlugin.isEnabled(config: block) == true)
        #expect(HermesPlugin.isEnabled(config: "plugins:\n  enabled:\n  - nunsseop # mine\n") == true)
        #expect(HermesPlugin.isEnabled(config: "plugins:\n  enabled: [orca-status, 'nunsseop']\n") == true)
        #expect(HermesPlugin.isEnabled(config: "plugins:\n  enabled:\n    - orca-status\n") == false)
        #expect(HermesPlugin.isEnabled(config: "plugins:\n  enabled: []\n") == false)
        #expect(HermesPlugin.isEnabled(config: "plugins:\n  enabled: null\n") == false)
        // Nothing about plugins: none is enabled.
        #expect(HermesPlugin.isEnabled(config: "model:\n  default: x\n") == false && HermesPlugin.isEnabled(config: "") == false)
        #expect(HermesPlugin.isEnabled(config: "plugins:\n  disabled:\n    - nunsseop\n") == false)
        // Only the list of plugins.enabled counts, wherever else the name stands.
        #expect(HermesPlugin.isEnabled(config: "toolsets:\n  enabled:\n    - nunsseop\nplugins:\n  enabled:\n    - other\n") == false)
        #expect(HermesPlugin.isEnabled(config: "plugins:\n  hooks:\n    enabled:\n      - nunsseop\n  enabled:\n    - other\n") == false)
    }

    @Test func aFormThatIsNotUnderstoodIsNotGuessedAt() {
        #expect(HermesPlugin.isEnabled(config: "plugins: {enabled: [nunsseop]}\n") == nil)
        #expect(HermesPlugin.isEnabled(config: "plugins:\n  enabled: nunsseop\n") == nil)
        #expect(HermesPlugin.isEnabled(config: "plugins:\n  enabled: [nunsseop\n") == nil)
    }

    @Test func theCommandIsTheOneTheDocsGive() {
        #expect(HermesPlugin.enableCommand == "hermes plugins enable nunsseop")
    }

    @Test func noSecretLeavesTheFileBecauseOnlyTheListIsKept() throws {
        try withTempHome { home in
            let folder = home.appendingPathComponent(".hermes")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("api_key: sk-secret\nplugins:\n  enabled:\n    - nunsseop\n".utf8).write(to: folder.appendingPathComponent("config.yaml"))
            #expect(HermesPlugin.isEnabled() == true)
            try FileManager.default.removeItem(at: folder.appendingPathComponent("config.yaml"))
            #expect(HermesPlugin.isEnabled() == nil)
        }
    }
}

struct HermesInstallTests {
    private let tool = NotifyIntegration.hermes
    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func hermes(_ home: URL) throws -> URL {
        let folder = home.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("plugins/orca-status"), withIntermediateDirectories: true)
        try Data("# Managed by Orca\n".utf8).write(to: folder.appendingPathComponent("plugins/orca-status/__init__.py"))
        try Data("plugins:\n  enabled:\n    - orca-status\n".utf8).write(to: folder.appendingPathComponent("config.yaml"))
        return folder
    }

    @Test func aToolIsOfferedOnlyWhereItHasBeenUsed() throws {
        try withTempHome { home in
            #expect(!tool.isPresent)
            _ = try hermes(home)
            #expect(tool.isPresent && tool.name == "Hermes" && tool.agentKind == .hermes)
            #expect(tool.configURL.path == home.appendingPathComponent(".hermes/plugins/nunsseop/__init__.py").path)
            #expect(NotifyIntegration.reportingSessions.contains(.hermes) && NotifyIntegration.askingForPermission(present: [.hermes]).isEmpty)
        }
    }

    @Test func connectingWritesThePluginOnceAndTouchesNothingElse() throws {
        try withTempHome { home in
            let folder = try hermes(home)
            let config = try Data(contentsOf: folder.appendingPathComponent("config.yaml"))
            let other = try Data(contentsOf: folder.appendingPathComponent("plugins/orca-status/__init__.py"))
            #expect(!tool.isInstalled)
            try tool.install()
            #expect(tool.isInstalled && text(tool.configURL) == HermesPlugin.source() && text(HermesPlugin.manifestURL) == HermesPlugin.manifest)
            // The config file, which turns a plugin on, is the user's to change: neither read for its secrets nor written.
            #expect(try Data(contentsOf: folder.appendingPathComponent("config.yaml")) == config)
            #expect(try Data(contentsOf: folder.appendingPathComponent("plugins/orca-status/__init__.py")) == other)
            let written = try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date
            Thread.sleep(forTimeInterval: 0.02)
            try tool.install()
            #expect(try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date == written)
            #expect(!FileManager.default.fileExists(atPath: tool.configURL.appendingPathExtension("nunsseop-backup").path))

            // Python's compiled copy goes with the plugin, and so does the folder; the other plugins stay.
            try FileManager.default.createDirectory(at: HermesPlugin.folder.appendingPathComponent("__pycache__"), withIntermediateDirectories: true)
            try tool.uninstall()
            #expect(!tool.isInstalled && !FileManager.default.fileExists(atPath: HermesPlugin.folder.path))
            #expect(try Data(contentsOf: folder.appendingPathComponent("plugins/orca-status/__init__.py")) == other)
            #expect(try Data(contentsOf: folder.appendingPathComponent("config.yaml")) == config)
            try tool.uninstall()
        }
    }

    @Test func aFolderOfTheSameNameWithAnotherPluginInItIsKeptAsABackupAndNeverRemoved() throws {
        try withTempHome { home in
            _ = try hermes(home)
            try FileManager.default.createDirectory(at: HermesPlugin.folder, withIntermediateDirectories: true)
            try Data("def register(ctx): pass\n".utf8).write(to: tool.configURL)
            #expect(!tool.isInstalled)
            NotifyIntegration.updateConnectedNow()
            try tool.uninstall()
            #expect(text(tool.configURL) == "def register(ctx): pass\n")
            try tool.install()
            #expect(tool.isInstalled && text(tool.configURL.appendingPathExtension("nunsseop-backup")) == "def register(ctx): pass\n")
            // Anything else the user keeps in the folder stays when the plugin goes.
            try Data("notes\n".utf8).write(to: HermesPlugin.folder.appendingPathComponent("README.md"))
            try tool.uninstall()
            #expect(FileManager.default.fileExists(atPath: HermesPlugin.folder.appendingPathComponent("README.md").path) && !tool.isInstalled)
        }
    }

    @Test func theLaunchBringsAConnectedPluginUpToDateAndLeavesAnUnconnectedOneAlone() throws {
        try withTempHome { home in
            _ = try hermes(home)
            NotifyIntegration.updateConnectedNow()
            #expect(!FileManager.default.fileExists(atPath: HermesPlugin.folder.path))
            try tool.install()
            try Data((HermesPlugin.marker + " (older)\n").utf8).write(to: tool.configURL)
            NotifyIntegration.updateConnectedNow()
            #expect(text(tool.configURL) == HermesPlugin.source())
        }
    }
}

/// The real plugin run by python3 as Hermes would call it (a context whose `register_hook` it gives its hooks), against the real server.
@MainActor
struct HermesRunTests {
    private static let fake = """
        import sys, time, json
        sys.path.insert(0, ".")
        import plugin
        hooks = {}
        class Ctx:
            def register_hook(self, name, callback):
                hooks[name] = callback
        plugin.register(Ctx())
        def fire(name, *args, **kwargs):
            return hooks[name](*args, **kwargs)
        def out(value):
            print(json.dumps(value), flush=True)

        """

    private func run(_ server: PermissionTestServer, _ body: String, port: UInt16? = nil, environment: [String: String] = [:])
        throws -> (script: PythonScript, events: AgentEventLog, notices: ServerNotices) {
        let events = AgentEventLog(), notices = ServerNotices()
        server.server.onAgent = { events.add($0) }
        server.server.onNotify = { notices.add($0) }
        let script = try PythonScript(files: ["plugin/__init__.py": HermesPlugin.source(port: port ?? server.port)],
                                      main: Self.fake + body, home: server.home.url, environment: environment)
        return (script, events, notices)
    }

    @Test(.enabled(if: PythonTool.available, PythonTool.reason))
    func aTerminalSessionIsReportedFromItsStartToItsEndAndAFinishedTurnShowsAsANotice() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (script, events, notices) = try run(server, """
            session = "20261017_090000_ab12cd"
            kinds = {"platform": "cli", "model": "m"}
            fire("on_session_start", session_id=session, **kinds)
            out({"returned": fire("pre_llm_call", session_id=session, user_message="secret", conversation_history=[], is_first_turn=True, **kinds)})
            fire("pre_approval_request", command="rm -rf x", description="d", pattern_key="k", pattern_keys=["k"], session_key="s", surface="cli")
            fire("on_human_input_request", kind="approval", request_id="r", session_id=session, session_key="s", platform="cli", prompt="[redacted]")
            fire("post_approval_response", command="rm -rf x", choice="once", surface="cli")
            fire("post_tool_call", "bash", {}, "ok")
            out({"returned": fire("post_llm_call", session_id=session, user_message="secret", assistant_response="done", conversation_history=[], **kinds)})
            fire("on_session_end", session_id=session, completed=True, interrupted=False, **kinds)
            fire("on_session_finalize", session_id=session, platform="cli")
            time.sleep(0.5)
            out({"done": True})
            """, environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty", "HERDR_PANE_ID": "w1:p1"])
        let result = try #require(await script.finish())
        #expect(result.status == 0 && result.lines.count == 3)
        // A hook returns nothing: what pre_llm_call returns would be put into the prompt.
        #expect(result.lines.prefix(2).allSatisfy { $0["returned"] is NSNull })
        await eventually { events.events.count >= 6 && notices.notices.count >= 1 }
        #expect(events.events.map(\.action) == [.opened, .working, .needsInput, .working, .finished, .remove])
        #expect(events.events.allSatisfy { $0.session == "20261017_090000_ab12cd" && $0.agent == .hermes && $0.app == "com.mitchellh.ghostty" && $0.inHerdr })
        #expect(events.events.allSatisfy { $0.pid == script.process.process.processIdentifier })
        #expect(notices.notices.map(\.title) == ["Hermes"] && notices.notices.first?.message == "Finished" && notices.notices.first?.app == "com.mitchellh.ghostty")
    }

    @Test(.enabled(if: PythonTool.available, PythonTool.reason))
    func aTurnThatEndedWithoutAnAnswerIsInterruptedAndTheGatewaysSessionsAreNotReported() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let (script, events, notices) = try run(server, """
            session = "20261017_090001_cd34ef"
            fire("on_session_start", session_id="gateway-1", platform="telegram", model="m")
            fire("pre_llm_call", session_id="gateway-1", platform="telegram", user_message="x", is_first_turn=True, model="m", conversation_history=[])
            fire("post_llm_call", session_id="gateway-1", platform="telegram", user_message="x", assistant_response="y", model="m", conversation_history=[])
            fire("pre_approval_request", command="c", description="d", pattern_key="k", pattern_keys=[], session_key="s", surface="gateway")
            time.sleep(0.3)
            out({"gateway": True})
            fire("on_session_start", session_id=session, platform="tui", model="m")
            fire("pre_llm_call", session_id=session, platform="tui", user_message="x", is_first_turn=True, model="m", conversation_history=[])
            fire("on_session_end", session_id=session, completed=False, interrupted=True, model="m", platform="tui")
            time.sleep(0.5)
            out({"done": True})
            """)
        let result = try #require(await script.finish())
        #expect(result.status == 0 && result.lines.count == 2)
        await eventually { events.events.count >= 3 }
        #expect(events.events.map(\.action) == [.opened, .working, .idle] && events.events.allSatisfy { $0.session == "20261017_090001_cd34ef" })
        #expect(notices.notices.isEmpty)
    }

    @Test(.enabled(if: PythonTool.available, PythonTool.reason))
    func aMissingHeaderFileNoServerAndAHookThatIsGivenOddThingsCostHermesNothing() async throws {
        for token in [String?.none, String(repeating: "t", count: 40)] {
            let home = try ScratchHome(token: token)
            let script = try PythonScript(files: ["plugin/__init__.py": HermesPlugin.source(port: 1)],
                                          main: Self.fake + """
                                          fire("on_session_start", session_id=12345, platform="cli")
                                          fire("pre_llm_call", session_id=None, platform=None)
                                          fire("pre_llm_call", session_id="s", platform="cli", user_message=object())
                                          fire("post_llm_call", session_id="s", platform="cli")
                                          fire("on_human_input_request", kind=3)
                                          fire("on_session_end")
                                          time.sleep(0.2)
                                          out({"survived": True})
                                          """, home: home.url)
            let result = try #require(await script.finish())
            #expect(result.status == 0 && result.lines.first?["survived"] as? Bool == true, "token \(token ?? "none")")
        }
    }

    @Test(.enabled(if: PythonTool.available, PythonTool.reason))
    func aContextThatRefusesAHookDoesNotStopTheOthers() async throws {
        let server = try await PermissionTestServer(token: String(repeating: "t", count: 40))
        let script = try PythonScript(files: ["plugin/__init__.py": HermesPlugin.source(port: server.port)], main: """
            import sys, json
            sys.path.insert(0, ".")
            import plugin
            names = []
            class Ctx:
                def register_hook(self, name, callback):
                    if name == "on_session_finalize":
                        raise ValueError("unknown hook")
                    names.append(name)
            plugin.register(Ctx())
            print(json.dumps({"names": names}))
            """, home: server.home.url)
        let result = try #require(await script.finish())
        let names = try #require(result.lines.first?["names"] as? [String])
        #expect(Set(names) == ["on_session_start", "pre_llm_call", "post_llm_call", "on_session_end", "pre_approval_request",
                               "on_human_input_request", "post_approval_response", "post_tool_call"])
    }
}

/// The notices the server was sent.
final class ServerNotices: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NotifyServer.Notice] = []
    var notices: [NotifyServer.Notice] { lock.withLock { stored } }
    func add(_ notice: NotifyServer.Notice) { lock.withLock { stored.append(notice) } }
}
