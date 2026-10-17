import Foundation
import Testing
@testable import Nunsseop

/// Antigravity's hooks as https://antigravity.google/docs/hooks describes them: a file of hook names, each with its events; stdin is camelCase
/// with `conversationId`, `workspacePaths`, `transcriptPath`, `modelName` and, for `PreToolUse`, `toolCall` with `name` and `args`.
private enum Agy {
    static let conversation = "0d7e1c1a-5a0e-4a58-93a6-6f1d2b7c9e42"

    static func payload(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["conversationId": conversation, "workspacePaths": ["/Users/me/secret-project"], "transcriptPath": "/Users/me/secret-transcript",
         "artifactDirectoryPath": "/Users/me/.gemini/antigravity/brain/x", "modelName": "gemini-3-pro"].merging(extra) { $1 }
    }

    static func toolCall(_ name: String, _ args: [String: Any]) -> [String: Any] {
        payload(["toolCall": ["name": name, "args": args], "stepIdx": 3])
    }

    static func handlers(_ event: String, permissions: Bool = true) -> [[String: Any]] {
        let group = AntigravityHooks.group(permissions: permissions)
        return ((group[event] as? [[String: Any]]) ?? []).flatMap { entry in
            (entry["hooks"] as? [[String: Any]]) ?? [entry]
        }
    }

    static func commands(_ event: String, permissions: Bool = true) -> [String] { handlers(event, permissions: permissions).compactMap { $0["command"] as? String } }

    static func text(_ group: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [AntigravityHooks.name: group], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

struct AntigravityHookGroupTests {
    @Test func theGroupIsPinned() {
        #expect(Golden.matches(Agy.text(AntigravityHooks.group(permissions: true)), named: "antigravity-hooks.json"), "UPDATE_GOLDENS=1 rewrites")
        #expect(Golden.matches(Agy.text(AntigravityHooks.group(permissions: false)), named: "antigravity-hooks-without-approvals.json"),
                "UPDATE_GOLDENS=1 rewrites")
    }

    @Test func theGroupHasTheShapesTheDocsGive() throws {
        let group = AntigravityHooks.group(permissions: true)
        #expect(Set(group.keys) == ["SessionStart", "PreInvocation", "Stop", "PreToolUse"])
        // The events without a matcher take their handlers directly; the tool event a matcher (a regular expression) and a list.
        for event in ["SessionStart", "PreInvocation", "Stop"] {
            for handler in try #require(group[event] as? [[String: Any]]) {
                #expect(Set(handler.keys) == ["type", "command", "timeout"] && handler["timeout"] as? Int == 10, "\(event)")
            }
        }
        let tool = try #require((group["PreToolUse"] as? [[String: Any]])?.first)
        #expect(tool["matcher"] as? String == "run_command|write_to_file|replace_file_content|multi_replace_file_content")
        #expect((tool["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 600 && (tool["hooks"] as? [Any])?.count == 1)
        #expect(AntigravityHooks.group(permissions: false)["PreToolUse"] == nil)
        // Every hook of the group names the tool, and none carries a secret.
        let text = Agy.text(group)
        for secret in ["Bearer", "notify-token"] { #expect(!text.contains(secret)) }
        #expect(Agy.commands("SessionStart")[0].contains("X-Agent: agy") && Agy.commands("PreToolUse")[0].contains("X-Agent: agy"))
    }
}

struct AntigravityInstallTests {
    private let tool = NotifyIntegration.antigravity

    /// Entries as other tools put them into the file (Orca's and Muxy's here), in the shapes the docs show.
    private let others = """
    {
      "muxy": {"Stop": [{"command": "muxy-hook stop", "timeout": 3}], "enabled": true},
      "orca-status": {
        "SessionStart": [{"type": "command", "command": "orca-hook start"}],
        "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "orca-hook tool", "timeout": 5}]}]
      }
    }
    """

    private func put(_ text: String) throws {
        try FileManager.default.createDirectory(at: tool.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: tool.configURL)
    }

    private func load() throws -> [String: Any] { try NotifyIntegration.loadJSON(at: tool.configURL) }
    private func sameJSON(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }

    @Test func theFileIsTheOneAntigravitySharesWithOtherTools() throws {
        try withTempHome { home in
            #expect(tool.configURL.path == home.appendingPathComponent(".gemini/config/hooks.json").path && tool.name == "Antigravity")
            #expect(!tool.isPresent)
            // Gemini CLI's folder alone is not Antigravity.
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
            #expect(!tool.isPresent)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"), withIntermediateDirectories: true)
            #expect(tool.isPresent)
            #expect(tool.agentKind == .agy && NotifyIntegration.reportingSessions.contains(.antigravity))
            #expect(NotifyIntegration.askingForPermission(present: [.antigravity]) == [.antigravity])
        }
    }

    @Test func connectingAddsOurGroupAndKeepsEveryOtherToolsEntryAsItWas() throws {
        try withTempHome { _ in
            try put(others)
            let before = try load()
            #expect(!tool.isInstalled)
            try tool.install()
            let after = try load()
            #expect(tool.isInstalled && Set(after.keys) == ["muxy", "orca-status", "nunsseop"])
            #expect(sameJSON(try #require(after["nunsseop"] as? [String: Any]), AntigravityHooks.group(permissions: true)))
            for name in ["muxy", "orca-status"] { #expect(NSDictionary(dictionary: [name: after[name] as Any]).isEqual(to: [name: before[name] as Any]), "\(name)") }
            #expect(try Data(contentsOf: tool.configURL.appendingPathExtension("nunsseop-backup")) == Data(others.utf8))

            // Connected again, nothing is written.
            let written = try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date
            Thread.sleep(forTimeInterval: 0.02)
            try tool.install()
            #expect(try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date == written)

            try tool.uninstall()
            let restored = try load()
            #expect(!tool.isInstalled && sameJSON(restored, before))
            try tool.uninstall()
        }
    }

    @Test func aFileThatIsNotThereIsMadeAndRemovedAgain() throws {
        try withTempHome { _ in
            try tool.install()
            #expect(tool.isInstalled && !FileManager.default.fileExists(atPath: tool.configURL.appendingPathExtension("nunsseop-backup").path))
            try tool.uninstall()
            #expect(try load().isEmpty)
        }
    }

    @Test func aGroupOfTheSameNameThatIsAnotherToolsIsNeverReplaced() throws {
        try withTempHome { _ in
            let seed = #"{"nunsseop":{"Stop":[{"command":"somebody-elses.sh"}]}}"#
            try put(seed)
            #expect(!tool.isInstalled)
            #expect(throws: NotifyIntegration.IntegrationError.self) { try tool.install() }
            try tool.uninstall()
            #expect(try Data(contentsOf: tool.configURL) == Data(seed.utf8))
        }
    }

    @Test func aFileThatCantBeReadIsLeftAlone() throws {
        try withTempHome { _ in
            for seed in ["{", "[1]", "// c\n{}"] {
                try put(seed)
                #expect(throws: (any Error).self) { try tool.install() }
                #expect(try Data(contentsOf: tool.configURL) == Data(seed.utf8))
            }
        }
    }

    @Test func theLaunchRefreshesAConnectionAndTheSettingDecidesWhetherApprovalsAreIn() throws {
        try withTempHome { _ in
            try put(others)
            try NotifyIntegration.$permissionPromptsOverride.withValue(false) { try tool.install() }
            let without = try #require(try load()["nunsseop"] as? [String: Any])
            #expect(sameJSON(without, AntigravityHooks.group(permissions: false)) && without["PreToolUse"] == nil)
            NotifyIntegration.$permissionPromptsOverride.withValue(true) { NotifyIntegration.updateConnectedNow() }
            let with = try #require(try load()["nunsseop"] as? [String: Any])
            #expect(sameJSON(with, AntigravityHooks.group(permissions: true)))
            // Not connected: the launch puts nothing there.
            try tool.uninstall()
            NotifyIntegration.updateConnectedNow()
            #expect(!tool.isInstalled)
        }
    }
}

struct AntigravityEventTests {
    private func run(_ event: String, _ extra: [String: Any] = [:], index: Int = 0, curlExit: Int32 = 0,
                     environment: [String: String] = ["__CFBundleIdentifier": "com.mitchellh.ghostty"]) throws -> (event: AgentEvent?, run: ShellRun) {
        try ToolHook.run(Agy.commands(event)[index], Agy.payload(extra), environment: environment, curlExit: curlExit)
    }

    @Test func eachEventBecomesTheBoardStateTheDocsImply() throws {
        let cases: [(String, [String: Any], AgentAction)] = [
            ("SessionStart", [:], .opened),
            ("PreInvocation", ["invocationNum": 1, "initialNumSteps": 0], .working),
            ("Stop", ["executionNum": 1, "terminationReason": "done", "fullyIdle": true], .finished),
        ]
        for (name, extra, action) in cases {
            let (event, sent) = try run(name, extra)
            #expect(event == AgentEvent(session: Agy.conversation, action: action, app: "com.mitchellh.ghostty", agent: .agy, pid: getpid()), "\(name)")
            #expect(!sent.args.joined().contains("secret") && sent.body.isEmpty && sent.stdout.isEmpty && sent.status == 0, "\(name)")
        }
    }

    @Test func aStopWithWorkLeftIsNeitherAFinishedHandNorANotice() throws {
        let extra: [String: Any] = ["executionNum": 1, "terminationReason": "done", "fullyIdle": false]
        for index in 0..<2 {
            let (event, sent) = try run("Stop", extra, index: index)
            #expect(event == nil && sent.curlCalls == 0 && sent.status == 0 && sent.stdout.isEmpty, "handler \(index)")
        }
    }

    @Test func aFinishedTurnAlsoShowsAsANotice() throws {
        let sent = try run("Stop", ["fullyIdle": true], index: 1).run
        #expect(sent.curlCalls == 1 && sent.args.contains("Finished") && sent.args.contains("X-Title: Antigravity"))
        #expect(sent.args.contains("X-App: com.mitchellh.ghostty") && sent.args.contains("http://127.0.0.1:\(NotifyServer.port)/notify"))
    }

    @MainActor
    @Test func aTurnGoesThroughTheBoardAndItsRowCarriesTheToolsName() throws {
        let board = AgentBoard()
        let hooks = AgentHooks(board: board, agent: .agy, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }, isAlive: { _ in true })
        let now = Date.now
        func apply(_ name: String, _ extra: [String: Any] = [:], _ step: Double) throws {
            hooks.apply(try #require(try run(name, extra, environment: [:]).event), now: now.addingTimeInterval(step))
        }
        try apply("SessionStart", [:], 1)
        try apply("PreInvocation", [:], 2)
        #expect(board.counts == AgentBoard.Counts(working: 1))
        try apply("Stop", ["fullyIdle": true], 3)
        let row = try #require(board.entries(now: now.addingTimeInterval(3)).first)
        #expect(row.agent.state == .waiting && row.agent.finished && AgentRow.toolName(row.agent.tool) == "Antigravity")
    }

    @MainActor
    @Test func twoConversationsOfOneProcessAreBothKept() {
        // The hooks may run in a process that more than one conversation shares.
        let board = AgentBoard()
        let hooks = AgentHooks(board: board, agent: .agy, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }, isAlive: { _ in true })
        hooks.apply(AgentEvent(session: "a", action: .working, agent: .agy, pid: 900))
        hooks.apply(AgentEvent(session: "b", action: .working, agent: .agy, pid: 900))
        #expect(board.counts == AgentBoard.Counts(working: 2))
    }

    @Test func noHookEverFailsOrPrintsWhenNunsseopIsNotRunning() throws {
        for event in ["SessionStart", "PreInvocation", "Stop"] {
            for index in Agy.commands(event).indices {
                let (_, sent) = try run(event, ["fullyIdle": true], index: index, curlExit: 7)
                #expect(sent.status == 0 && sent.stdout.isEmpty, "\(event)")
            }
        }
    }
}

@MainActor
struct AntigravityApprovalTests {
    private func body(_ name: String, _ args: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: Agy.toolCall(name, args)) }

    private func card(_ name: String, _ args: [String: Any]) throws -> PermissionPrompt {
        try #require(PermissionPrompt.parse(body(name, args), dialect: .agy)).prompt
    }

    @Test func aCommandShowsItsCommandLineAndTheRestOfItsArguments() throws {
        let prompt = try card("run_command", ["CommandLine": "npm run build", "Cwd": "/Users/me/secret-project/web", "WaitMsBeforeAsync": 500, "RunPersistent": false])
        #expect(prompt.title == "Run a command" && prompt.symbol == "terminal" && prompt.detail == "npm run build" && prompt.folder == "web")
        #expect(prompt.tag == "Antigravity" && prompt.grant == nil && !prompt.isCodex)
        #expect(prompt.secondary == "Cwd: /Users/me/secret-project/web\nRunPersistent: false\nWaitMsBeforeAsync: 500")
        #expect(PermissionLayout.hasThirdButton(prompt, .card))
    }

    @Test func aFileWriteAndAnEditShowThePathAndWhatGoesIn() throws {
        let write = try card("write_to_file", ["TargetFile": "/Users/me/p/a.txt", "CodeContent": "hello\nworld", "Overwrite": true, "Description": "greeting"])
        #expect(write.title == "Write a file" && write.detail == "/Users/me/p/a.txt\ncontent:\nhello\nworld")
        #expect(write.secondary == "Description: greeting\nOverwrite: true")
        let edit = try card("replace_file_content", ["TargetFile": "/Users/me/p/a.txt", "TargetContent": "old", "ReplacementContent": "new", "StartLine": 1])
        #expect(edit.title == "Edit a file" && edit.detail == "/Users/me/p/a.txt\nold:\nold\nnew:\nnew" && edit.secondary == "StartLine: 1")
        let many = try card("multi_replace_file_content", ["TargetFile": "/Users/me/p/a.txt", "ReplacementChunks": [["TargetContent": "a", "ReplacementContent": "b"]]])
        #expect(many.title == "Edit a file" && many.detail == "/Users/me/p/a.txt" && many.secondary.contains("ReplacementChunks: [{"))
    }

    @Test func aCallThatIsNotPutToTheUserGetsNoCard() throws {
        for name in ["view_file", "grep_search", "list_dir", "search_web", "invoke_subagent", "nonsense"] {
            #expect(PermissionPrompt.parse(body(name, ["AbsolutePath": "/x"]), dialect: .agy) == nil, "\(name)")
        }
        #expect(PermissionPrompt.parse(Data(#"{"conversationId":"x"}"#.utf8), dialect: .agy) == nil)
        #expect(PermissionPrompt.parse(Data("nope".utf8), dialect: .agy) == nil)
    }

    @Test func theAnswersAreInAntigravitysWords() {
        func text(_ answer: PermissionAnswer) -> String? {
            PermissionWire.decision(answer, suggestion: nil, dialect: .agy).map { String(decoding: $0, as: UTF8.self) }
        }
        // auto_approve, not allow: allow would only hand the question on to the next hook and Antigravity's own policy.
        #expect(text(.allow) == #"{"decision":"auto_approve","reason":"Allowed in Nunsseop"}"#)
        #expect(text(.deny) == #"{"decision":"deny","reason":"Denied in Nunsseop"}"#)
        #expect(text(.always) == nil && text(.terminal) == nil)
    }

    private func hook(for server: PermissionTestServer, _ input: Data) throws -> HookProcess {
        try HookProcess(command: NotifyServer.permissionHookCommand(port: server.port, agent: .agy), home: server.home.url, stdin: input)
    }

    @Test func allowDenyAndAnswerInTerminalThroughTheRealHook() async throws {
        let server = try await PermissionTestServer()
        let input = body("run_command", ["CommandLine": "make", "Cwd": "/Users/me/p"])
        for (answer, expected) in [(PermissionAnswer.allow, #"{"decision":"auto_approve","reason":"Allowed in Nunsseop"}"#),
                                   (.deny, #"{"decision":"deny","reason":"Denied in Nunsseop"}"#), (.terminal, "")] {
            let before = server.events.prompts.count
            let process = try hook(for: server, input)
            await eventually { server.events.prompts.count == before + 1 }
            let prompt = try #require(server.events.prompts.last)
            #expect(prompt.tag == "Antigravity" && prompt.detail == "make")
            server.server.permissions.answer(prompt.id, answer)
            let result = try #require(await process.finish())
            #expect(result.stdout == expected && result.status == 0, "\(answer)")
        }
    }

    @Test func aToolThatIsNotPutToTheUserNeverReachesTheServer() async throws {
        let server = try await PermissionTestServer()
        let process = try hook(for: server, body("view_file", ["AbsolutePath": "/Users/me/p/a.txt"]))
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0 && server.events.prompts.isEmpty)
    }

    /// Only the command and the file changes start the exchange with the server: the shell asks for the tool's name first.
    @Test func theShellLooksAtTheToolsNameBeforeItEverStartsTheExchange() throws {
        let command = NotifyServer.permissionHookCommand(port: NotifyServer.port, agent: .agy)
        #expect(command.contains("plutil -extract toolCall.name raw"))
        for name in PermissionDialect.antigravityTools { #expect(command.contains(name)) }
        let first = try #require(command.range(of: "case $(printf %s \"$in\" | plutil -extract toolCall.name"))
        let exchange = try #require(command.range(of: "openssl dgst"))
        #expect(first.lowerBound < exchange.lowerBound)
    }

    @Test func aHookWithNoNunsseopPrintsNothingAndEndsWithZero() async throws {
        let home = try ScratchHome(token: nil, permissionKey: String(repeating: "k", count: 40))
        let process = try HookProcess(command: NotifyServer.permissionHookCommand(port: 1, agent: .agy), home: home.url,
                                      stdin: body("run_command", ["CommandLine": "ls"]))
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0)
    }
}
