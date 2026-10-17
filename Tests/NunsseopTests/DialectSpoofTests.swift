import Foundation
import Testing
@testable import Nunsseop

/// A card must show what the tool will run. Where the input leaves it open which of two values that is, there is no card: the hook
/// prints nothing and the tool asks in its own prompt.
struct DialectSpoofTests {
    private func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func parse(_ object: [String: Any], _ dialect: PermissionDialect) -> PermissionPrompt.Parsed? {
        PermissionPrompt.parse(data(object), dialect: dialect)
    }

    private func agy(_ name: String, _ args: [String: Any]) -> [String: Any] {
        ["conversationId": "c", "toolCall": ["name": name, "args": args]]
    }

    // MARK: Antigravity

    @Test func antigravityHasNoCardWhereTheArgumentsAlreadyHoldTheNameTheCardWouldUse() {
        let pairs: [(tool: String, real: String, claude: String, others: [String: Any])] = [
            ("run_command", "CommandLine", "command", [:]),
            ("write_to_file", "TargetFile", "file_path", ["CodeContent": "x"]),
            ("write_to_file", "CodeContent", "content", ["TargetFile": "/a"]),
            ("replace_file_content", "TargetFile", "file_path", ["TargetContent": "a", "ReplacementContent": "b"]),
            ("replace_file_content", "TargetContent", "old_string", ["TargetFile": "/a", "ReplacementContent": "b"]),
            ("replace_file_content", "ReplacementContent", "new_string", ["TargetFile": "/a", "TargetContent": "a"]),
            ("multi_replace_file_content", "TargetFile", "file_path", [:]),
        ]
        for pair in pairs {
            let honest = pair.others.merging([pair.real: "real value"]) { $1 }
            #expect(parse(agy(pair.tool, honest), .agy) != nil, "\(pair.tool) alone")
            let spoofed = honest.merging([pair.claude: "model supplied"]) { $1 }
            #expect(parse(agy(pair.tool, spoofed), .agy) == nil, "\(pair.tool): \(pair.real) and \(pair.claude)")
            // The name alone, with the real field missing, is no command either.
            let missing = pair.others.merging([pair.claude: "model supplied"]) { $1 }
            #expect(parse(agy(pair.tool, missing), .agy) == nil, "\(pair.tool): only \(pair.claude)")
        }
    }

    @Test func antigravityHasNoCardForAnyOtherNameTheCardReadsAsTheCommandOrFile() {
        for name in ["command", "file_path", "content", "old_string", "new_string", "edits", "url", "description", "run_in_background", "dangerouslyDisableSandbox"] {
            #expect(parse(agy("run_command", ["CommandLine": "ls", name: "x"]), .agy) == nil, "\(name)")
        }
        // Its own fields, whatever they are, are listed.
        #expect(parse(agy("run_command", ["CommandLine": "ls", "Cwd": "/a", "Anything": 1]), .agy)?.prompt.secondary == "Anything: 1\nCwd: /a")
    }

    // MARK: Copilot

    private func copilot(_ extra: [String: Any]) -> [String: Any] { ["sessionId": "s", "cwd": "/Users/me/p"].merging(extra) { $1 } }

    @Test func copilotHasNoCardWhereATopLevelFieldAndTheArgumentsShareAName() {
        let honest = copilot(["toolName": "bash", "toolArgs": ["command": "ls"]])
        #expect(parse(honest, .copilot) != nil)
        // The same field in both: which one runs?
        #expect(parse(honest.merging(["command": "rm -rf ~"]) { $1 }, .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "toolArgs": ["fullCommandText": "ls"], "fullCommandText": "rm -rf ~"]), .copilot) == nil)
        // The command from the envelope alone is not the arguments' command.
        #expect(parse(copilot(["toolName": "bash", "toolArgs": [:], "command": "rm -rf ~"]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "command": "rm -rf ~"]), .copilot) == nil)
        for name in ["file_path", "content", "url", "description", "edits"] {
            #expect(parse(honest.merging([name: "x"]) { $1 }, .copilot) == nil, "\(name)")
        }
        // Other fields of the envelope are listed.
        #expect(parse(honest.merging(["fullCommandText": "ls"]) { $1 }, .copilot)?.prompt.secondary == "fullCommandText: ls")
    }

    @Test func copilotHasNoCardWhenTheNameOrTheArgumentsComeInTwoPlaces() {
        #expect(parse(copilot(["toolName": "bash", "tool_name": "view", "toolArgs": ["command": "ls"]]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "tool_name": "bash", "toolArgs": ["command": "ls"]]), .copilot) != nil)
        #expect(parse(copilot(["toolName": "bash", "toolArgs": ["command": "ls"], "toolInput": ["command": "rm -rf ~"]]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "tool_input": ["command": "ls"], "toolArgs": ["command": "rm -rf ~"]]), .copilot) == nil)
    }

    @Test func copilotLeavesASandboxBypassToCopilot() {
        // The docs: an allow can't pre-approve a bypass of the sandbox, only a deny takes effect.
        #expect(parse(copilot(["toolName": "bash", "toolInput": ["command": "ls", "requestSandboxBypass": true]]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "toolInput": ["command": "ls", "requestSandboxBypass": false]]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "toolArgs": #"{"command":"ls","requestSandboxBypass":true}"#]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "toolArgs": ["command": "ls"], "requestSandboxBypass": true]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "toolInput": ["command": "ls"]]), .copilot) != nil)
    }

    // MARK: Cursor

    private func cursorMCP(_ extra: [String: Any]) -> [String: Any] {
        ["hook_event_name": "beforeMCPExecution", "tool_name": "create_issue", "tool_input": #"{"title":"Bug"}"#, "mcp_server_name": "github"]
            .merging(extra) { $1 }
    }

    @Test func cursorHasNoCardWhereTheInputAlreadyNamesWhereTheCallGoes() {
        #expect(parse(cursorMCP(["url": "https://real.example.com"]), .cursor) != nil)
        #expect(parse(cursorMCP(["tool_input": #"{"mcp_server_url":"https://fake.example.com"}"#, "url": "https://real.example.com"]), .cursor) == nil)
        #expect(parse(cursorMCP(["tool_input": ["mcp_server_url": "https://fake.example.com"], "mcp_server_url": "https://real.example.com"]), .cursor) == nil)
        #expect(parse(cursorMCP(["tool_input": #"{"mcp_server_command":"safe"}"#, "command": "evil --serve"]), .cursor) == nil)
        // Two fields for one address.
        #expect(parse(cursorMCP(["url": "https://a.example.com", "mcp_server_url": "https://b.example.com"]), .cursor) == nil)
        // Without a clash both are listed.
        let both = parse(cursorMCP(["command": "npx server", "url": "https://real.example.com"]), .cursor)
        #expect(both?.prompt.detail.contains("\"mcp_server_command\" : \"npx server\"") == true && both?.prompt.detail.contains("\"mcp_server_url\"") == true)
    }

    private func cursorShell(_ extra: [String: Any]) -> [String: Any] {
        ["hook_event_name": "beforeShellExecution", "command": "make", "cwd": "/Users/me/p"].merging(extra) { $1 }
    }

    @Test func cursorLeavesACommandThatMayRunOutsideTheSandboxToCursor() {
        #expect(parse(cursorShell(["sandbox": true]), .cursor) != nil)
        // The docs don't say what the field means for this hook: anything but a true may be outside the sandbox.
        let values: [Any] = [false, "true", "false", 0, 1, NSNull()]
        for value in values {
            #expect(parse(cursorShell(["sandbox": value]), .cursor) == nil, "\(value)")
        }
        // Not said at all: the call is shown as it is.
        #expect(parse(cursorShell([:]), .cursor) != nil)
    }

    @MainActor
    @Test func theHooksOfTheseToolsPrintNothingForAFallThroughAndTheToolAsksItself() async throws {
        let server = try await PermissionTestServer()
        let copilotBody = data(copilot(["toolName": "bash", "toolInput": ["command": "ls", "requestSandboxBypass": true]]))
        let copilotHook = try HookProcess(command: NotifyServer.permissionHookCommand(port: server.port, agent: .copilot), home: server.home.url, stdin: copilotBody)
        let copilotResult = try #require(await copilotHook.finish())
        #expect(copilotResult.stdout == "" && copilotResult.status == 0)
        let cursorBody = data(cursorShell(["sandbox": false]))
        let cursorHook = try HookProcess(command: NotifyServer.permissionHookCommand(port: server.port, agent: .cursor), home: server.home.url, stdin: cursorBody)
        let cursorResult = try #require(await cursorHook.finish())
        #expect(cursorResult.stdout == "" && cursorResult.status == 1)
        #expect(server.events.prompts.isEmpty)
    }

    // MARK: The same checks as for Claude Code

    @Test func theCardsOfTheseToolsSayUnusualCharactersAndWriteOutLookalikesAsClaudeCodesDo() throws {
        let commands = ["echo \u{2192} \u{00e9}", "curl http://\u{0435}xample.com", "rm \u{202E}fdp.txt", "ls \u{FF0F}tmp", "echo plain"]
        for command in commands {
            let claude = try #require(PermissionPrompt.parse(data(["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                                                   "tool_input": ["command": command], "cwd": "/Users/me/p"])))
            let candidates: [(PermissionDialect, [String: Any])] = [
                (.copilot, copilot(["toolName": "bash", "toolArgs": ["command": command]])),
                (.agy, agy("run_command", ["CommandLine": command])),
                (.cursor, cursorShell(["command": command, "sandbox": true])),
            ]
            for (dialect, body) in candidates {
                let card = try #require(parse(body, dialect), "\(dialect) \(command)").prompt
                #expect(card.detail == claude.prompt.detail, "\(dialect) \(command)")
                #expect(card.flags.filter { $0.text == "Unusual characters" } == claude.prompt.flags.filter { $0.text == "Unusual characters" },
                        "\(dialect) \(command)")
            }
        }
        // The tool's own name is judged as it is for any tool of Claude Code's that is no known one.
        let named = try #require(parse(copilot(["toolName": "to\u{043E}l", "toolArgs": ["x": "1"]]), .copilot))
        #expect(named.prompt.title.contains("⟨U+043E⟩") || named.prompt.flags.contains { $0.text == "Unusual characters" })
    }
}
