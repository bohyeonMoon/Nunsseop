import Foundation
import Testing
@testable import Nunsseop

/// GitHub Copilot CLI's hooks as https://docs.github.com/en/copilot/reference/hooks-configuration describes them: camelCase events whose
/// input has `sessionId`, `timestamp` (milliseconds), `cwd`; `notification` adds `notification_type` and `message`.
private enum Copilot {
    static let session = "7c0f6d52-3c43-4a58-8f5c-0b8a2f9d1e11"

    static func payload(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["sessionId": session, "timestamp": 1_760_000_000_000, "cwd": "/Users/me/secret-project"].merging(extra) { $1 }
    }

    /// The file as JSON.
    static func hooks(permissions: Bool = true) throws -> [String: [[String: Any]]] {
        let file = try #require(try JSONSerialization.jsonObject(with: Data(CopilotHooks.source(permissions: permissions).utf8)) as? [String: Any])
        return try #require(file["hooks"] as? [String: [[String: Any]]])
    }

    static func commands(_ event: String, permissions: Bool = true) throws -> [String] {
        try hooks(permissions: permissions)[event, default: []].compactMap { $0["bash"] as? String }
    }
}

struct CopilotHookFileTests {
    @Test func theFileIsPinned() {
        #expect(Golden.matches(CopilotHooks.source(permissions: true), named: "copilot-hooks.json"), "UPDATE_GOLDENS=1 rewrites")
        #expect(Golden.matches(CopilotHooks.source(permissions: false), named: "copilot-hooks-without-approvals.json"), "UPDATE_GOLDENS=1 rewrites")
    }

    @Test func theFileHasTheShapeTheDocsGiveAndNoSecret() throws {
        let text = CopilotHooks.source(permissions: true)
        let file = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(file["version"] as? Int == 1 && Set(file.keys) == ["version", "hooks"])
        let hooks = try Copilot.hooks()
        #expect(Set(hooks.keys) == ["sessionStart", "userPromptSubmitted", "agentStop", "sessionEnd", "notification", "permissionRequest"])
        for (event, entries) in hooks {
            for entry in entries {
                #expect(entry["type"] as? String == "command" && Set(entry.keys) == ["type", "bash", "timeoutSec"], "\(event)")
                #expect(entry["timeoutSec"] as? Int == (event == "permissionRequest" ? 600 : 10), "\(event)")
            }
        }
        #expect(hooks["notification"]?.count == 2 && hooks["permissionRequest"]?.count == 1)
        // The token and the key are read from their files when a hook runs; neither is in the file or on a command line.
        for secret in ["Bearer", "notify-token", "permission-key="] { #expect(!text.contains(secret), "\(secret)") }
        #expect(text.contains("notify-auth") && text.contains("permission-key"))
        #expect(try Copilot.hooks(permissions: false)["permissionRequest"] == nil)
    }

    @Test func approvalsAreLeftOutWhenTheNotchDoesNotAnswerThem() throws {
        let off = try Copilot.hooks(permissions: false)
        #expect(Set(off.keys) == ["sessionStart", "userPromptSubmitted", "agentStop", "sessionEnd", "notification"])
    }
}

struct CopilotInstallTests {
    private let tool = NotifyIntegration.copilot
    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func backup(of url: URL) -> URL { url.appendingPathExtension("nunsseop-backup") }

    private func folder(_ home: URL) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot/hooks"), withIntermediateDirectories: true)
    }

    @Test func aToolIsOfferedOnlyWhereItHasBeenUsedAndItsFileIsInTheHooksFolder() throws {
        try withTempHome { home in
            #expect(!tool.isPresent)
            try folder(home)
            #expect(tool.isPresent && tool.name == "GitHub Copilot")
            #expect(tool.configURL.path == home.appendingPathComponent(".copilot/hooks/nunsseop.json").path)
            #expect(NotifyIntegration.reportingSessions.contains(.copilot) && tool.agentKind == .copilot)
            #expect(NotifyIntegration.askingForPermission(present: [.copilot]) == [.copilot])
        }
    }

    @Test func connectingWritesOurOwnFileAndLeavesOtherHookFilesAlone() throws {
        try withTempHome { home in
            try folder(home)
            let theirs = home.appendingPathComponent(".copilot/hooks/theirs.json")
            let theirText = #"{"version":1,"hooks":{"sessionStart":[{"type":"command","bash":"echo hi","timeoutSec":5}]}}"#
            try Data(theirText.utf8).write(to: theirs)
            let settings = home.appendingPathComponent(".copilot/settings.json")
            try Data(#"{"model":"gpt-5"}"#.utf8).write(to: settings)

            #expect(!tool.isInstalled)
            try tool.install()
            #expect(tool.isInstalled && text(tool.configURL) == CopilotHooks.source(permissions: true))
            #expect(text(theirs) == theirText && text(settings) == #"{"model":"gpt-5"}"#)
            #expect(!FileManager.default.fileExists(atPath: backup(of: tool.configURL).path))

            // Connected again, nothing is written.
            let written = try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date
            Thread.sleep(forTimeInterval: 0.02)
            try tool.install()
            #expect(try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date == written)

            try tool.uninstall()
            #expect(!tool.isInstalled && !FileManager.default.fileExists(atPath: tool.configURL.path))
            #expect(text(theirs) == theirText && text(settings) == #"{"model":"gpt-5"}"#)
            try tool.uninstall()
        }
    }

    @Test func aFileOfTheSameNameThatIsNotOursIsKeptAndNeverRemoved() throws {
        try withTempHome { home in
            try folder(home)
            let mine = #"{"version":1,"hooks":{"agentStop":[{"type":"command","bash":"mine.sh"}]}}"#
            try Data(mine.utf8).write(to: tool.configURL)
            #expect(!tool.isInstalled)
            NotifyIntegration.updateConnectedNow()
            try tool.uninstall()
            #expect(text(tool.configURL) == mine)
            try tool.install()
            #expect(tool.isInstalled && text(backup(of: tool.configURL)) == mine)
            // An older version of ours is replaced without the backup being it.
            let older = CopilotHooks.source(permissions: true).replacingOccurrences(of: "\"timeoutSec\" : 10", with: "\"timeoutSec\" : 3")
            try Data(older.utf8).write(to: tool.configURL)
            #expect(tool.isInstalled)
            NotifyIntegration.updateConnectedNow()
            #expect(text(tool.configURL) == CopilotHooks.source(permissions: true) && text(backup(of: tool.configURL)) == mine)
        }
    }

    @Test func theSettingForApprovalsDecidesWhetherThePermissionHookIsThere() throws {
        try withTempHome { home in
            try folder(home)
            try NotifyIntegration.$permissionPromptsOverride.withValue(false) { try tool.install() }
            #expect(text(tool.configURL) == CopilotHooks.source(permissions: false))
            // Turning it on brings the hook in at the next update, as for the other tools.
            NotifyIntegration.$permissionPromptsOverride.withValue(true) { NotifyIntegration.updateConnectedNow() }
            #expect(text(tool.configURL) == CopilotHooks.source(permissions: true))
            NotifyIntegration.$permissionPromptsOverride.withValue(false) { NotifyIntegration.updateConnectedNow() }
            #expect(text(tool.configURL) == CopilotHooks.source(permissions: false))
        }
    }
}

struct CopilotEventTests {
    private func run(_ event: String, _ extra: [String: Any] = [:], index: Int = 0, curlExit: Int32 = 0,
                     environment: [String: String] = ["__CFBundleIdentifier": "com.apple.Terminal"]) throws -> (event: AgentEvent?, run: ShellRun) {
        try ToolHook.run(Copilot.commands(event)[index], Copilot.payload(extra), environment: environment, curlExit: curlExit)
    }

    @Test func eachEventBecomesTheBoardStateTheDocsImply() throws {
        let cases: [(String, [String: Any], AgentAction)] = [
            ("sessionStart", ["source": "startup", "initialPrompt": "secret prompt"], .opened),
            ("userPromptSubmitted", ["prompt": "secret prompt"], .working),
            ("notification", ["hook_event_name": "Notification", "message": "needs you", "notification_type": "permission_prompt"], .needsInput),
            ("notification", ["hook_event_name": "Notification", "message": "needs you", "notification_type": "elicitation_dialog"], .needsInput),
            ("notification", ["hook_event_name": "Notification", "message": "idle", "notification_type": "agent_idle"], .idle),
            ("agentStop", ["transcriptPath": "/Users/me/secret", "stopReason": "end_turn", "stop_hook_active": false], .finished),
            ("sessionEnd", ["reason": "complete"], .remove),
        ]
        for (name, extra, action) in cases {
            let (event, sent) = try run(name, extra)
            #expect(event == AgentEvent(session: Copilot.session, action: action, app: "com.apple.Terminal", agent: .copilot, pid: getpid()),
                    "\(name) \(extra["notification_type"] ?? "")")
            #expect(!sent.args.joined().contains("secret") && sent.body.isEmpty && sent.stdout.isEmpty && sent.status == 0, "\(name)")
        }
    }

    @Test func aNotificationOfAnotherTypeSaysNothingAboutWork() throws {
        for type in ["shell_completed", "shell_detached_completed", "agent_completed"] {
            let (event, _) = try run("notification", ["notification_type": type])
            #expect(event == nil, "\(type)")
        }
    }

    @Test func theNoticeShowsCopilotsOwnMessageForWhatNeedsTheUserAndNothingElse() throws {
        for type in ["permission_prompt", "elicitation_dialog", "agent_idle"] {
            let sent = try ShellRun.run({ _ in ["-c", CopilotHooks.noticeCommand] },
                                        stdin: ToolHook.json(Copilot.payload(["message": "Copilot needs you", "notification_type": type])),
                                        environment: ["__CFBundleIdentifier": "com.apple.Terminal"])
            #expect(sent.curlCalls == 1 && sent.body == "Copilot needs you\n" && sent.args.contains("X-Title: GitHub Copilot"), "\(type)")
            #expect(sent.args.contains("X-App: com.apple.Terminal") && sent.stdout.isEmpty && sent.status == 0)
        }
        for type in ["shell_completed", "agent_completed", "something_new"] {
            let sent = try ShellRun.run({ _ in ["-c", CopilotHooks.noticeCommand] },
                                        stdin: ToolHook.json(Copilot.payload(["message": "done", "notification_type": type])))
            #expect(sent.curlCalls == 0 && sent.stdout.isEmpty && sent.status == 0, "\(type)")
        }
    }

    @MainActor
    @Test func aTurnGoesThroughTheBoard() throws {
        let board = AgentBoard()
        let hooks = AgentHooks(board: board, agent: .copilot, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }, isAlive: { _ in true })
        let now = Date.now
        var step = 0.0
        func apply(_ name: String, _ extra: [String: Any] = [:]) throws {
            step += 1
            hooks.apply(try #require(try run(name, extra, environment: [:]).event), now: now.addingTimeInterval(step))
        }
        try apply("sessionStart")
        try apply("userPromptSubmitted")
        #expect(board.counts == AgentBoard.Counts(working: 1))
        try apply("notification", ["notification_type": "permission_prompt"])
        #expect(board.counts == AgentBoard.Counts(waiting: 1))
        try apply("userPromptSubmitted")
        try apply("agentStop")
        let row = try #require(board.entries(now: now.addingTimeInterval(step)).first)
        #expect(row.agent.state == .waiting && row.agent.finished && AgentRow.toolName(row.agent.tool) == "GitHub Copilot")
        try apply("sessionEnd")
        #expect(board.entries(now: now.addingTimeInterval(step)).isEmpty)
    }

    @Test func noHookEverFailsOrPrintsWhenNunsseopIsNotRunning() throws {
        let hooks = try Copilot.hooks(permissions: false)
        for (event, entries) in hooks {
            for index in entries.indices {
                for curlExit in [Int32(7), 28] {
                    let (_, sent) = try run(event, ["notification_type": "permission_prompt", "message": "m"], index: index, curlExit: curlExit)
                    #expect(sent.status == 0 && sent.stdout.isEmpty, "\(event)")
                }
            }
        }
    }
}

@MainActor
struct CopilotApprovalTests {
    private func body(_ extra: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: Copilot.payload(extra))
    }

    private func card(_ extra: [String: Any]) throws -> PermissionPrompt {
        try #require(PermissionPrompt.parse(body(extra), dialect: .copilot)).prompt
    }

    @Test func aCommandIsShownAsCopilotsAndWithoutAlwaysAllow() throws {
        // toolArgs is a JSON string in Copilot's hooks, an object in the VS Code compatible format.
        for args in [#"{"command":"npm test","description":"Run the tests"}"# as Any, ["command": "npm test", "description": "Run the tests"] as Any] {
            let prompt = try card(["toolName": "bash", "toolArgs": args])
            #expect(prompt.title == "Run a command" && prompt.symbol == "terminal" && prompt.detail == "npm test" && prompt.folder == "secret-project")
            #expect(prompt.tag == "Copilot" && prompt.grant == nil && !prompt.isCodex && prompt.secondary == "description: Run the tests")
            #expect(PermissionLayout.hasThirdButton(prompt, .card))
        }
        let parsed = try #require(PermissionPrompt.parse(body(["toolName": "bash", "toolInput": ["command": "ls"]]), dialect: .copilot))
        #expect(parsed.dialect == .copilot && parsed.suggestion == nil && !parsed.openCode && parsed.questionInput == nil)
    }

    @Test func anyOtherToolIsItsOwnNameWithEverythingItWasGiven() throws {
        let prompt = try card(["toolName": "github-mcp-server-create_issue", "toolArgs": #"{"title":"Bug","labels":["a"]}"#,
                               "requestSandboxBypass": true])
        #expect(prompt.title == "github-mcp-server-create_issue" && prompt.symbol == "puzzlepiece.extension")
        #expect(prompt.detail.contains("\"title\" : \"Bug\"") && prompt.detail.contains("\"requestSandboxBypass\" : true"))
        // Arguments that are no JSON object are shown as they came.
        let plain = try card(["toolName": "view", "toolArgs": "/Users/me/file.txt"])
        #expect(plain.title == "view" && plain.detail.contains("/Users/me/file.txt"))
    }

    @Test func aRequestThatSaysNothingOfTheToolGetsNoCard() throws {
        #expect(PermissionPrompt.parse(body([:]), dialect: .copilot) == nil)
        #expect(PermissionPrompt.parse(body(["toolName": ""]), dialect: .copilot) == nil)
        #expect(PermissionPrompt.parse(Data("[1]".utf8), dialect: .copilot) == nil)
        #expect(PermissionPrompt.parse(Data("not json".utf8), dialect: .copilot) == nil)
    }

    @Test func unusualCharactersAreSaidAndNothingTheToolSendsIsTheTitle() throws {
        let spoof = try card(["toolName": "bash", "toolArgs": ["command": "rm \u{202E}fdp.txt"]])
        #expect(spoof.detail.contains("⟨U+202E⟩") && spoof.title == "Run a command")
        // Cyrillic letters among ASCII ones are written out rather than shown.
        let lookalike = try card(["toolName": "bash", "toolArgs": ["command": "curl http://\u{0435}xample.com"]])
        #expect(lookalike.detail == "curl http://⟨U+0435⟩xample.com")
        // Letters of other scripts that are not written out are said.
        let foreign = try card(["toolName": "bash", "toolArgs": ["command": "echo \u{2192} \u{00e9}"]])
        #expect(foreign.flags.contains { $0.text == "Unusual characters" && $0.warns })
    }

    @Test func theAnswersAreInCopilotsWords() throws {
        func text(_ answer: PermissionAnswer) -> String? {
            PermissionWire.decision(answer, suggestion: nil, dialect: .copilot).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(text(.allow) == #"{"behavior":"allow"}"#)
        #expect(text(.deny) == #"{"behavior":"deny","message":"Denied in Nunsseop"}"#)
        #expect(text(.always) == nil && text(.terminal) == nil && text(.answered([0: [0]])) == nil)
    }

    private func hook(for server: PermissionTestServer, _ input: Data) throws -> HookProcess {
        try HookProcess(command: NotifyServer.permissionHookCommand(port: server.port, agent: .copilot), home: server.home.url, stdin: input)
    }

    @Test func allowDenyAndAnswerInTerminalThroughTheRealHook() async throws {
        let server = try await PermissionTestServer()
        let input = body(["toolName": "bash", "toolArgs": ["command": "npm test"]])
        for (answer, expected) in [(PermissionAnswer.allow, #"{"behavior":"allow"}"#),
                                   (.deny, #"{"behavior":"deny","message":"Denied in Nunsseop"}"#), (.terminal, "")] {
            let before = server.events.prompts.count
            let process = try hook(for: server, input)
            await eventually { server.events.prompts.count == before + 1 }
            let prompt = try #require(server.events.prompts.last)
            #expect(prompt.tag == "Copilot" && prompt.detail == "npm test")
            server.server.permissions.answer(prompt.id, answer)
            let result = try #require(await process.finish())
            #expect(result.stdout == expected && result.status == 0, "\(answer)")
        }
    }

    @Test func aRequestWithoutTheAgentHeaderIsReadAsClaudeCodesAndRefusesCopilotsShape() async throws {
        let server = try await PermissionTestServer()
        let process = try HookProcess(command: server.hookCommand, home: server.home.url, stdin: body(["toolName": "bash", "toolArgs": ["command": "ls"]]))
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0 && server.events.prompts.isEmpty)
    }

    @Test func aHookWithNoNunsseopOrNoKeyPrintsNothingAndEndsWithZero() async throws {
        let home = try ScratchHome(token: String(repeating: "t", count: 40), permissionKey: nil)
        let input = body(["toolName": "bash", "toolArgs": ["command": "ls"]])
        let noKey = try HookProcess(command: NotifyServer.permissionHookCommand(port: 1, agent: .copilot), home: home.url, stdin: input)
        let keyed = try ScratchHome(token: nil, permissionKey: String(repeating: "k", count: 40))
        let noServer = try HookProcess(command: NotifyServer.permissionHookCommand(port: 1, agent: .copilot), home: keyed.url, stdin: input)
        for process in [noKey, noServer] {
            let result = try #require(await process.finish())
            #expect(result.stdout == "" && result.status == 0)
        }
    }

    @Test func theTextForClaudeCodeIsTheOneAlreadyInstalled() {
        // Codex asks to trust a hook again when its command changes, so the text without an agent must not change.
        let text = NotifyServer.permissionHookCommand(port: 47750)
        #expect(Hash.sha256(text) == "5ddc27833b72edaed73c75dffb97d50624561444c0be387f532993f856b43eff")
        #expect(NotifyServer.permissionHookCommand(port: 47750, agent: .copilot) != text)
        #expect(NotifyServer.permissionHookCommand(port: 47750, agent: .copilot).contains("-H 'X-Agent: copilot'"))
    }
}
