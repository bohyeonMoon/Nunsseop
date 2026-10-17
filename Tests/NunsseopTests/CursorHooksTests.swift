import Foundation
import Testing
@testable import Nunsseop

/// Cursor's hooks as https://cursor.com/docs/hooks describes them: every event's input has `conversation_id`, `generation_id`, `model`,
/// `hook_event_name`, `workspace_roots`; the permission hooks answer `{"permission": ...}`; seconds are the unit of `timeout`.
private enum Cur {
    static let conversation = "c1f0a9e4-5b7d-4e0f-8f55-2f0e6a9d7b13"

    static func payload(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["conversation_id": conversation, "generation_id": "g-1", "model": "claude-sonnet", "hook_event_name": name,
         "cursor_version": "2.1.0", "workspace_roots": ["/Users/me/secret-project"], "user_email": "me@example.com",
         "transcript_path": "/Users/me/secret-transcript"].merging(extra) { $1 }
    }

    static func entries(_ event: String, permissions: Bool = true) -> [[String: Any]] {
        CursorHooks.table(permissions: permissions).filter { $0.event == event }.map(\.entry)
    }

    static func command(_ event: String, _ index: Int = 0) -> String { entries(event)[index]["command"] as? String ?? "" }

    static func text(permissions: Bool) -> String {
        var hooks: [String: [[String: Any]]] = [:]
        for (event, entry) in CursorHooks.table(permissions: permissions) { hooks[event, default: []].append(entry) }
        let data = (try? JSONSerialization.data(withJSONObject: ["version": 1, "hooks": hooks], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

struct CursorHookTableTests {
    @Test func theEntriesArePinned() {
        #expect(Golden.matches(Cur.text(permissions: true), named: "cursor-hooks.json"), "UPDATE_GOLDENS=1 rewrites")
        #expect(Golden.matches(Cur.text(permissions: false), named: "cursor-hooks-without-approvals.json"), "UPDATE_GOLDENS=1 rewrites")
    }

    @Test func theEntriesHaveTheShapeTheDocsGiveAndNoSecret() {
        let table = CursorHooks.table(permissions: true)
        #expect(Set(table.map(\.event)) == ["sessionStart", "beforeSubmitPrompt", "stop", "sessionEnd", "beforeShellExecution", "beforeMCPExecution"])
        for (event, entry) in table {
            #expect(Set(entry.keys) == ["command", "timeout"], "\(event)")
            #expect(entry["timeout"] as? Int == (event.hasPrefix("before") && event != "beforeSubmitPrompt" ? 600 : 10), "\(event)")
        }
        #expect(table.filter { $0.event == "stop" }.count == 2)
        let text = Cur.text(permissions: true)
        for secret in ["Bearer", "notify-token"] { #expect(!text.contains(secret)) }
        #expect(!CursorHooks.table(permissions: false).map(\.event).contains { $0.hasSuffix("Execution") })
        // The entries run in Cursor's own process, which hosts several conversations: no process is named.
        #expect(!text.contains("X-Pid"))
    }
}

struct CursorInstallTests {
    private let tool = NotifyIntegration.cursor

    /// Another tool's entries, as they are written into the file next to Nunsseop's, and a script a user wrote by hand.
    private let seed = """
    {
      "version": 1,
      "hooks": {
        "stop": [
          {"command": "./hooks/theirs-stop.sh", "timeout": 5},
          {"command": "curl -s -m 2 -X POST http://127.0.0.1:47750/notify -H 'X-Title: Script' --data-binary 'Done'"}
        ],
        "beforeShellExecution": [{"command": "orca-hook shell", "matcher": "git", "failClosed": true}],
        "afterFileEdit": [{"command": "./hooks/format.sh"}]
      },
      "somethingElse": {"keep": [1, 2, 3]}
    }
    """

    private func put(_ text: String) throws {
        try FileManager.default.createDirectory(at: tool.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: tool.configURL)
    }

    private func load() throws -> [String: Any] { try NotifyIntegration.loadJSON(at: tool.configURL) }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        (((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
    }

    @Test func theToolIsOfferedWhereCursorHasBeenUsed() throws {
        try withTempHome { home in
            #expect(!tool.isPresent)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
            #expect(tool.isPresent && tool.name == "Cursor" && tool.configURL.path == home.appendingPathComponent(".cursor/hooks.json").path)
            #expect(tool.agentKind == .cursor && NotifyIntegration.reportingSessions.contains(.cursor))
            #expect(NotifyIntegration.askingForPermission(present: [.cursor]) == [.cursor])
        }
    }

    @Test func connectingAddsOurEntriesAfterEveryOtherAndKeepsTheRestOfTheFileAsItWas() throws {
        try withTempHome { _ in
            try put(seed)
            let before = try load()
            try tool.install()
            let after = try load()
            #expect(tool.isInstalled && after["version"] as? Int == 1)
            #expect(NSDictionary(dictionary: ["k": after["somethingElse"] as Any]).isEqual(to: ["k": before["somethingElse"] as Any]))
            // The others' entries are where they were, in front of ours, with every field.
            let stop = commands(after, "stop")
            #expect(stop.count == 4 && Array(stop.prefix(2)) == commands(before, "stop") && stop[2...].allSatisfy { HookCommands.isOurs(command: $0, noticeTitles: ["Cursor"]) })
            let shell = try #require((after["hooks"] as? [String: Any])?["beforeShellExecution"] as? [[String: Any]])
            #expect(shell.count == 2 && shell[0]["command"] as? String == "orca-hook shell" && shell[0]["matcher"] as? String == "git" && shell[0]["failClosed"] as? Bool == true)
            #expect(commands(after, "afterFileEdit") == ["./hooks/format.sh"])
            #expect(try Data(contentsOf: tool.configURL.appendingPathExtension("nunsseop-backup")) == Data(seed.utf8))

            let written = try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date
            Thread.sleep(forTimeInterval: 0.02)
            try tool.install()
            #expect(try FileManager.default.attributesOfItem(atPath: tool.configURL.path)[.modificationDate] as? Date == written)

            try tool.uninstall()
            let removed = try load()
            #expect(!tool.isInstalled && NSDictionary(dictionary: removed).isEqual(to: before))
        }
    }

    @Test func aFileThatIsNotThereIsMadeWithItsVersionAndRemovedAgain() throws {
        try withTempHome { _ in
            try tool.install()
            let made = try load()
            #expect(tool.isInstalled && made["version"] as? Int == 1)
            try tool.uninstall()
            let removed = try load()
            #expect(!tool.isInstalled && (removed["hooks"] == nil) && removed["version"] as? Int == 1)
        }
    }

    @Test func aFileThatCantBeReadOrHasAnotherShapeIsLeftAlone() throws {
        try withTempHome { _ in
            for text in ["{", "[]", #"{"hooks": "x"}"#, #"{"hooks": {"stop": "x"}}"#] {
                try put(text)
                #expect(throws: (any Error).self) { try tool.install() }
                #expect(try Data(contentsOf: tool.configURL) == Data(text.utf8), "\(text)")
            }
        }
    }

    @Test func theLaunchRefreshesAConnectionAndTheSettingDecidesWhetherApprovalsAreIn() throws {
        try withTempHome { _ in
            try put(seed)
            try NotifyIntegration.$permissionPromptsOverride.withValue(false) { try tool.install() }
            let off = try load()
            #expect(commands(off, "beforeShellExecution") == ["orca-hook shell"])
            NotifyIntegration.$permissionPromptsOverride.withValue(true) { NotifyIntegration.updateConnectedNow() }
            let on = try load()
            #expect(commands(on, "beforeShellExecution").count == 2 && commands(on, "beforeMCPExecution").count == 1)
            NotifyIntegration.$permissionPromptsOverride.withValue(false) { NotifyIntegration.updateConnectedNow() }
            let again = try load()
            #expect(commands(again, "beforeShellExecution") == ["orca-hook shell"] && commands(again, "beforeMCPExecution").isEmpty)
            #expect(commands(again, "stop").first == "./hooks/theirs-stop.sh")
        }
    }

    @Test func aHandWrittenScriptCommandIsNotOurs() {
        let script = ["command": NotifyServer.scriptCommand]
        #expect(!CursorHooks.isOurs(entry: script) && !CursorHooks.holdsAny(in: ["hooks": ["stop": [script]]]))
        let removed = CursorHooks.removing(from: ["hooks": ["stop": [script]]])
        #expect(NSDictionary(dictionary: removed).isEqual(to: ["hooks": ["stop": [script]]]))
    }
}

struct CursorEventTests {
    private func run(_ event: String, _ extra: [String: Any] = [:], index: Int = 0, curlExit: Int32 = 0,
                     environment: [String: String] = ["__CFBundleIdentifier": CursorHooks.bundleID]) throws -> (event: AgentEvent?, run: ShellRun) {
        try ToolHook.run(Cur.command(event, index), Cur.payload(event, extra), environment: environment, curlExit: curlExit)
    }

    @Test func eachEventBecomesTheBoardStateTheDocsImply() throws {
        let cases: [(String, [String: Any], AgentAction)] = [
            ("sessionStart", ["session_id": "s-1", "is_background_agent": false, "composer_mode": "agent"], .opened),
            ("beforeSubmitPrompt", ["prompt": "secret prompt", "attachments": []], .working),
            ("stop", ["status": "completed", "loop_count": 0], .finished),
            ("stop", ["status": "aborted", "loop_count": 0], .idle),
            ("stop", ["status": "error", "loop_count": 0], .idle),
            ("sessionEnd", ["reason": "completed", "duration_ms": 1200], .remove),
        ]
        for (name, extra, action) in cases {
            let (event, sent) = try run(name, extra)
            #expect(event == AgentEvent(session: Cur.conversation, action: action, app: CursorHooks.bundleID, agent: .cursor), "\(name) \(extra["status"] ?? "")")
            #expect(!sent.args.joined().contains("secret") && !sent.args.joined().contains("example.com") && sent.body.isEmpty && sent.status == 0)
        }
    }

    @Test func theRowGoesToCursorWhateverMacOSNamesAndNoProcessIsSent() throws {
        // macOS names no app for a hook Cursor runs from a helper process: Cursor is the app.
        let (event, sent) = try run("sessionStart", environment: [:])
        #expect(event?.app == CursorHooks.bundleID && event?.pid == nil && !ToolHook.headers(of: sent).keys.contains("x-pid"))
        // Run from a terminal (Cursor's CLI), it is the terminal that macOS names.
        let terminal = try run("sessionStart", environment: ["__CFBundleIdentifier": "com.apple.Terminal"])
        #expect(terminal.event?.app == "com.apple.Terminal")
    }

    @Test func theHookThatRunsBeforeAPromptAnswersThatItMayGoOn() throws {
        let (_, sent) = try run("beforeSubmitPrompt")
        #expect(sent.stdout == #"{"continue":true}"# && sent.status == 0)
        for name in ["sessionStart", "stop", "sessionEnd"] { #expect(try run(name).run.stdout.isEmpty, "\(name)") }
    }

    @Test func onlyAFinishedTurnShowsAsANotice() throws {
        let completed = try run("stop", ["status": "completed"], index: 1).run
        #expect(completed.curlCalls == 1 && completed.args.contains("Finished") && completed.args.contains("X-Title: Cursor"))
        #expect(completed.args.contains("X-App: \(CursorHooks.bundleID)") && completed.status == 0 && completed.stdout.isEmpty)
        for status in ["aborted", "error"] {
            let sent = try run("stop", ["status": status], index: 1).run
            #expect(sent.curlCalls == 0 && sent.status == 0, "\(status)")
        }
    }

    @MainActor
    @Test func aTurnGoesThroughTheBoardAndSeveralConversationsAreKept() throws {
        let board = AgentBoard()
        let hooks = AgentHooks(board: board, agent: .cursor, isOn: { true }, watchesHerdr: { false }, frontmostApp: { nil }, isAlive: { _ in true })
        let now = Date.now
        func apply(_ name: String, _ extra: [String: Any] = [:], _ step: Double) throws {
            hooks.apply(try #require(try run(name, extra, environment: [:]).event), now: now.addingTimeInterval(step))
        }
        try apply("sessionStart", [:], 1)
        try apply("beforeSubmitPrompt", [:], 2)
        #expect(board.counts == AgentBoard.Counts(working: 1))
        try apply("stop", ["status": "completed"], 3)
        let entry = try #require(board.entries(now: now.addingTimeInterval(3)).first)
        #expect(entry.agent.state == .waiting && entry.agent.finished && AgentRow.toolName(entry.agent.tool) == "Cursor" && entry.agent.app == CursorHooks.bundleID)
        // Its row goes to the Cursor app: there is no terminal to find.
        let row = AgentRow(entry, transcript: nil)
        #expect(row.target == .app(CursorHooks.bundleID) && row.focusable)
        try apply("sessionEnd", [:], 4)
        #expect(board.entries(now: now.addingTimeInterval(4)).isEmpty)
    }

    @Test func noHookEverFailsOrPrintsWhenNunsseopIsNotRunningExceptTheAnswerThePromptHookGives() throws {
        for (event, entries) in Dictionary(grouping: CursorHooks.table(permissions: false), by: \.event) {
            for index in entries.indices {
                for curlExit in [Int32(7), 28] {
                    let (_, sent) = try run(event, ["status": "completed"], index: index, curlExit: curlExit)
                    #expect(sent.status == 0 && sent.stdout == (event == "beforeSubmitPrompt" ? #"{"continue":true}"# : ""), "\(event)")
                }
            }
        }
    }
}

@MainActor
struct CursorApprovalTests {
    private func shell(_ command: String = "npm test", extra: [String: Any] = [:]) -> Data {
        try! JSONSerialization.data(withJSONObject: Cur.payload("beforeShellExecution", ["command": command, "cwd": "/Users/me/secret-project/web", "sandbox": true].merging(extra) { $1 }))
    }

    private func mcp(extra: [String: Any] = [:]) -> Data {
        try! JSONSerialization.data(withJSONObject: Cur.payload("beforeMCPExecution", [
            "tool_name": "create_issue", "tool_input": #"{"title":"Bug","labels":["a"]}"#, "mcp_server_name": "github", "url": "https://mcp.example.com/sse",
        ].merging(extra) { $1 }))
    }

    private func card(_ body: Data) throws -> PermissionPrompt { try #require(PermissionPrompt.parse(body, dialect: .cursor)).prompt }

    @Test func aShellCommandIsShownAsCursorsWithItsFolderAndSandbox() throws {
        let prompt = try card(shell())
        #expect(prompt.title == "Run a command" && prompt.symbol == "terminal" && prompt.detail == "npm test" && prompt.folder == "web")
        #expect(prompt.tag == "Cursor" && prompt.grant == nil && prompt.secondary == "cwd: /Users/me/secret-project/web\nsandbox: true")
        #expect(PermissionLayout.hasThirdButton(prompt, .card))
        // Without a folder in the call, the first root of the workspace is it.
        let bare = try #require(PermissionPrompt.parse(try JSONSerialization.data(withJSONObject: Cur.payload("beforeShellExecution", ["command": "ls"])), dialect: .cursor))
        #expect(bare.prompt.folder == "secret-project")
    }

    @Test func anMCPCallIsItsOwnNameWithItsInputAndWhereItGoes() throws {
        let prompt = try card(mcp())
        #expect(prompt.title == "mcp__github__create_issue" && prompt.symbol == "puzzlepiece.extension")
        #expect(prompt.detail.contains("\"title\" : \"Bug\"") && prompt.detail.contains("\"mcp_server_url\" : \"https://mcp.example.com/sse\""))
        // An input that is no JSON object leaves open what runs: Cursor asks for itself.
        #expect(PermissionPrompt.parse(mcp(extra: ["tool_input": "just text"]), dialect: .cursor) == nil)
    }

    @Test func otherEventsAndEmptyCallsGetNoCard() throws {
        for name in ["preToolUse", "beforeReadFile", "afterFileEdit", "stop"] {
            #expect(PermissionPrompt.parse(try JSONSerialization.data(withJSONObject: Cur.payload(name, ["command": "ls", "tool_name": "x"])), dialect: .cursor) == nil, "\(name)")
        }
        #expect(PermissionPrompt.parse(shell(""), dialect: .cursor) == nil)
        #expect(PermissionPrompt.parse(mcp(extra: ["tool_name": ""]), dialect: .cursor) == nil)
    }

    @Test func nothingTheCallSendsIsTheTitle() throws {
        let spoof = try card(shell("ls \u{202E}gpj.exe"))
        #expect(spoof.title == "Run a command" && spoof.detail.contains("⟨U+202E⟩"))
        // The server's name is part of the title of an MCP call, and is written out as any name is.
        let named = try card(mcp(extra: ["mcp_server_name": "gith\u{200B}ub"]))
        #expect(named.title.contains("⟨U+200B⟩"))
    }

    @Test func theAnswersAreInCursorsWords() {
        func text(_ answer: PermissionAnswer) -> String? {
            PermissionWire.decision(answer, suggestion: nil, dialect: .cursor).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(text(.allow) == #"{"permission":"allow"}"#)
        #expect(text(.deny) == #"{"agent_message":"Denied in Nunsseop","permission":"deny","user_message":"Denied in Nunsseop"}"#)
        #expect(text(.always) == nil && text(.terminal) == nil)
    }

    private func hook(for server: PermissionTestServer, _ input: Data) throws -> HookProcess {
        try HookProcess(command: NotifyServer.permissionHookCommand(port: server.port, agent: .cursor), home: server.home.url, stdin: input)
    }

    /// Cursor reads an exit code of 1 as "the hook had nothing to say", where an empty answer of a permission hook may be read as a block.
    @Test func allowAndDenyAreAnsweredAndEverythingElseEndsWithOne() async throws {
        let server = try await PermissionTestServer()
        for (answer, expected, status) in [(PermissionAnswer.allow, #"{"permission":"allow"}"#, Int32(0)),
                                           (.deny, #"{"agent_message":"Denied in Nunsseop","permission":"deny","user_message":"Denied in Nunsseop"}"#, 0),
                                           (.terminal, "", 1)] {
            let before = server.events.prompts.count
            let process = try hook(for: server, shell("make"))
            await eventually { server.events.prompts.count == before + 1 }
            let prompt = try #require(server.events.prompts.last)
            #expect(prompt.tag == "Cursor" && prompt.detail == "make")
            server.server.permissions.answer(prompt.id, answer)
            let result = try #require(await process.finish())
            #expect(result.stdout == expected && result.status == status, "\(answer)")
        }
    }

    @Test func withNoNunsseopNoKeyOrNoCardTheHookSaysNothingAndEndsWithOne() async throws {
        let keyed = try ScratchHome(token: nil, permissionKey: String(repeating: "k", count: 40))
        let unkeyed = try ScratchHome(token: nil, permissionKey: nil)
        for home in [keyed, unkeyed] {
            let process = try HookProcess(command: NotifyServer.permissionHookCommand(port: 1, agent: .cursor), home: home.url, stdin: shell())
            let result = try #require(await process.finish())
            #expect(result.stdout == "" && result.status == 1)
        }
        let server = try await PermissionTestServer()
        server.server.permissions.isEnabled = { false }
        let disabled = try #require(await hook(for: server, shell()).finish())
        #expect(disabled.stdout == "" && disabled.status == 1 && server.events.prompts.isEmpty)
        let empty = try #require(await hook(for: server, Data()).finish())
        #expect(empty.stdout == "" && empty.status == 1)
    }

    @Test func theOtherToolsHooksStillEndWithZeroWhenTheyDecideNothing() {
        for agent in [AgentKind.copilot, .agy] {
            let command = NotifyServer.permissionHookCommand(port: 47750, agent: agent)
            #expect(!command.contains("exit 1") && command.hasSuffix("exit 0"))
        }
        #expect(NotifyServer.permissionHookCommand(port: 47750, agent: .cursor).hasSuffix("exit 1"))
    }
}
