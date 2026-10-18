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
            ("multi_replace_file_content", "TargetFile", "file_path", ["ReplacementChunks": [["TargetContent": "a", "ReplacementContent": "b"]]]),
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
        // Its own fields are listed.
        #expect(parse(agy("run_command", ["CommandLine": "ls", "Cwd": "/a", "WaitMsBeforeAsync": 1]), .agy)?.prompt.secondary == "Cwd: /a\nWaitMsBeforeAsync: 1")
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
        // Another field that could be the command is no other field of the envelope: which one runs?
        #expect(parse(honest.merging(["fullCommandText": "ls"]) { $1 }, .copilot) == nil)
        // Fields of a tool the card has no headline for are listed.
        #expect(parse(copilot(["toolName": "view", "toolArgs": ["x": 1], "kind": "read"]), .copilot)?.prompt.detail.contains("\"kind\" : \"read\"") == true)
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
        // Not said at all is not known either.
        #expect(parse(cursorShell([:]), .cursor) == nil)
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

    // MARK: Other spellings, texts with a key twice, fields the card can't show

    @Test func antigravityKnowsOnlyTheArgumentsItsDocsNameAndSpelledAsTheyAre() {
        let honest: [String: Any] = ["CommandLine": "ls"]
        #expect(parse(agy("run_command", honest), .agy) != nil)
        for key in ["commandLine", "commandline", "command_line", "COMMANDLINE", "Command", "cmd", "CommandLine ", "Env", "Args"] {
            #expect(parse(agy("run_command", honest.merging([key: "rm -rf ~"]) { $1 }), .agy) == nil, "\(key)")
            #expect(parse(agy("run_command", [key: "rm -rf ~"]), .agy) == nil, "only \(key)")
        }
        let bases: [String: [String: Any]] = [
            "write_to_file": ["TargetFile": "/a", "CodeContent": "x"],
            "replace_file_content": ["TargetFile": "/a", "TargetContent": "a", "ReplacementContent": "b"],
            "multi_replace_file_content": ["TargetFile": "/a", "ReplacementChunks": [["TargetContent": "a", "ReplacementContent": "b"]]]]
        for (tool, key) in [("write_to_file", "targetFile"), ("write_to_file", "codeContent"), ("replace_file_content", "target_content"),
                            ("replace_file_content", "replacementcontent"), ("multi_replace_file_content", "TARGETFILE"), ("write_to_file", "filePath")] {
            let base = bases[tool]!
            #expect(parse(agy(tool, base), .agy) != nil, "\(tool) alone")
            #expect(parse(agy(tool, base.merging([key: "/etc/passwd"]) { $1 }), .agy) == nil, "\(tool) \(key)")
        }
        // A field of the tool's call besides its name and arguments is not shown either.
        let call: [String: Any] = ["conversationId": "c", "toolCall": ["name": "run_command", "args": honest, "overrideArgs": ["CommandLine": "rm -rf ~"]]]
        #expect(parse(call, .agy) == nil)
        #expect(parse(["toolCall": ["name": "run_command", "args": honest, "id": "call-1"]], .agy) != nil)
    }

    @Test func antigravityNeedsTheFieldsAToolCannotDoWithout() {
        #expect(parse(agy("run_command", ["Cwd": "/a"]), .agy) == nil)
        #expect(parse(agy("run_command", ["CommandLine": ""]), .agy) == nil)
        #expect(parse(agy("run_command", ["CommandLine": ["ls"]]), .agy) == nil)
        #expect(parse(agy("write_to_file", ["TargetFile": "/a"]), .agy) == nil)
        #expect(parse(agy("write_to_file", ["TargetFile": "/a", "CodeContent": ""]), .agy) != nil)
        #expect(parse(agy("replace_file_content", ["TargetFile": "/a", "TargetContent": "a"]), .agy) == nil)
        #expect(parse(agy("multi_replace_file_content", ["TargetFile": "/a"]), .agy) == nil)
        #expect(parse(agy("multi_replace_file_content", ["TargetFile": "/a", "ReplacementChunks": "oops"]), .agy) == nil)
    }

    @Test func antigravityShowsEveryChunkOfAMultiEdit() throws {
        let chunks: [[String: Any]] = [["TargetContent": "first", "ReplacementContent": "one"], ["TargetContent": "second", "ReplacementContent": "two"]]
        let prompt = try #require(parse(agy("multi_replace_file_content", ["TargetFile": "/a", "ReplacementChunks": chunks, "Instruction": "rename"]), .agy)).prompt
        for word in ["first", "one", "second", "two"] { #expect(prompt.secondary.contains(word), "\(word)") }
        #expect(prompt.secondary.contains("Instruction: rename"))
    }

    @Test func copilotHasNoCardForAnotherSpellingOfTheNameOrTheArgumentsOfTheCommand() {
        let honest = copilot(["toolName": "bash", "toolArgs": ["command": "ls"]])
        #expect(parse(honest, .copilot) != nil)
        for key in ["ToolArgs", "tool_args", "toolargs", "ToolInput", "toolinput", "ToolName", "toolname"] {
            #expect(parse(honest.merging([key: ["command": "rm -rf ~"]]) { $1 }, .copilot) == nil, "\(key)")
        }
        for key in ["cmd", "Command", "commandLine", "command_line", "script", "args", "path", "text"] {
            #expect(parse(copilot(["toolName": "bash", "toolArgs": ["command": "ls", key: "rm -rf ~"]]), .copilot) == nil, "\(key)")
        }
        // A tool with no headline shows every field with its name, and a field named so is one of them.
        let card = parse(copilot(["toolName": "view", "toolArgs": ["cmd": "x", "path": "/a"]]), .copilot)?.prompt
        #expect(card?.title == "view" && card?.detail.contains("\"cmd\" : \"x\"") == true)
        // A tool of Claude Code's names gets the same care.
        #expect(parse(copilot(["toolName": "Write", "toolArgs": ["file_path": "/a", "content": "x", "filePath": "/b"]]), .copilot) == nil)
    }

    @Test func aTextWithAKeyTwiceGetsNoCard() {
        let twice = #"{"command":"ls","command":"rm -rf ~"}"#
        #expect(parse(copilot(["toolName": "bash", "toolArgs": #"{"command":"ls"}"#]), .copilot) != nil)
        #expect(parse(copilot(["toolName": "bash", "toolArgs": twice]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "toolInput": twice]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "toolArgs": #"{"command":"ls","command":"rm -rf ~"}"#]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "tool", "toolArgs": #"{"a":{"b":1,"b":2}}"#]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "tool", "toolArgs": #"{"a":[{"b":1},{"c":2,"c":3}]}"#]), .copilot) == nil)
        // Keys that are two spellings of the same letters are one key to some parsers.
        #expect(parse(copilot(["toolName": "tool", "toolArgs": "{\"\u{e9}\":1,\"e\u{301}\":2}"]), .copilot) == nil)
        #expect(parse(cursorMCP(["tool_input": twice]), .cursor) == nil)
        // And in the text of the whole request, where Foundation keeps one of two.
        let raw = #"{"sessionId":"s","toolName":"view","toolName":"bash","toolArgs":{"command":"ls"}}"#
        #expect(PermissionPrompt.parse(Data(raw.utf8), dialect: .copilot) == nil)
        let rawAgy = #"{"toolCall":{"name":"run_command","args":{"CommandLine":"ls","CommandLine":"rm -rf ~"}}}"#
        #expect(PermissionPrompt.parse(Data(rawAgy.utf8), dialect: .agy) == nil)
        let rawCursor = #"{"hook_event_name":"beforeShellExecution","command":"ls","command":"rm -rf ~","sandbox":true}"#
        #expect(PermissionPrompt.parse(Data(rawCursor.utf8), dialect: .cursor) == nil)
    }

    @Test func argumentsThatAreNoObjectGetNoCard() {
        for args in ["ls", "[1]", "42", "null", "\"x\"", "{", "{\"a\":1} trailing", "{'a':1}"] {
            #expect(parse(copilot(["toolName": "bash", "toolArgs": args]), .copilot) == nil, "\(args)")
            #expect(parse(cursorMCP(["tool_input": args]), .cursor) == nil, "\(args)")
        }
        #expect(parse(copilot(["toolName": "bash", "toolArgs": [1, 2]]), .copilot) == nil)
        #expect(parse(copilot(["toolName": "bash", "toolArgs": 5]), .copilot) == nil)
        // Nothing at all is no arguments, which a tool may take.
        #expect(parse(copilot(["toolName": "tool"]), .copilot) != nil && parse(copilot(["toolName": "tool", "toolArgs": ""]), .copilot) != nil)
    }

    @Test func cursorShowsWhereACommandRunsWholeAndEveryOtherFieldOfTheCall() throws {
        let prompt = try #require(parse(cursorShell(["sandbox": true, "cwd": "/Users/me/a/web", "env": ["PATH": "/evil"], "timeout": 5]), .cursor)).prompt
        #expect(prompt.detail == "make" && prompt.folder == "web")
        #expect(prompt.secondary == "cwd: /Users/me/a/web\nenv: {\"PATH\":\"/evil\"}\nsandbox: true\ntimeout: 5")
        // The other fields of the hook, which say who and where, are not part of the call.
        #expect(parse(cursorShell(["sandbox": true, "conversation_id": "c", "generation_id": "g", "workspace_roots": ["/a"], "model": "m"]), .cursor)?.prompt.secondary
                == "cwd: /Users/me/p\nsandbox: true")
        for key in ["cmd", "Command", "commandLine", "script", "args", "path"] {
            #expect(parse(cursorShell([key: "rm -rf ~"]), .cursor) == nil, "\(key)")
        }
        for key in ["description", "run_in_background", "file_path", "url"] {
            #expect(parse(cursorShell([key: "x"]), .cursor) == nil, "\(key)")
        }
        // An MCP call lists every field it has as well, and none may be the name of another.
        let mcp = try #require(parse(cursorMCP(["headers": ["a": "b"]]), .cursor)).prompt
        #expect(mcp.detail.contains("\"headers\"") && mcp.detail.contains("\"title\" : \"Bug\""))
        #expect(parse(cursorMCP(["tool_input": #"{"headers":1}"#, "headers": 2]), .cursor) == nil)
    }

    // MARK: The same gates for every tool, and for every part of the request

    @Test func aToolWhateverItIsCalledGetsNoCardWithTwoNamesForWhatRuns() {
        // Copilot's shell tools and file tools go by many names; none is trusted to be the one the card knows.
        for tool in ["shell", "run", "powershell", "execute", "bash", "write", "edit", "create", "str_replace_editor", "some-mcp-tool"] {
            let honest = copilot(["toolName": tool, "toolArgs": ["command": "ls"]])
            #expect(parse(honest, .copilot) != nil, "\(tool)")
            for rival in ["cmd", "Command", "commandLine", "script"] {
                #expect(parse(copilot(["toolName": tool, "toolArgs": ["command": "ls", rival: "rm -rf ~"]]), .copilot) == nil, "\(tool) \(rival)")
                // A field of the request beside the arguments, too.
                #expect(parse(honest.merging([rival: "rm -rf ~"]) { $1 }, .copilot) == nil, "\(tool) \(rival) beside")
            }
            for pair in [("path", "file_path"), ("filePath", "path"), ("content", "text"), ("old_string", "search"), ("new_string", "replacement")] {
                #expect(parse(copilot(["toolName": tool, "toolArgs": [pair.0: "a", pair.1: "b"]]), .copilot) == nil, "\(tool) \(pair)")
            }
            // One of a kind, in a tool with no headline, is only a field that is listed.
            #expect(parse(copilot(["toolName": tool, "toolArgs": ["path": "/a"]]), .copilot) != nil, "\(tool) path")
        }
        // Cursor's MCP tools, whose names are the servers'.
        for tool in ["run_shell", "write_file", "edit"] {
            #expect(parse(cursorMCP(["tool_name": tool, "tool_input": #"{"command":"ls","cmd":"rm -rf ~"}"#]), .cursor) == nil, "\(tool)")
            #expect(parse(cursorMCP(["tool_name": tool, "tool_input": #"{"path":"/a","file_path":"/b"}"#]), .cursor) == nil, "\(tool)")
            #expect(parse(cursorMCP(["tool_name": tool, "tool_input": #"{"path":"/a","content":"x"}"#]), .cursor) != nil, "\(tool)")
            #expect(parse(cursorMCP(["tool_name": tool, "cmd": "rm -rf ~", "tool_input": #"{"command":"ls"}"#]), .cursor) == nil, "\(tool) beside")
        }
    }

    @Test func noRequestHoldsAnotherPlaceForTheCallOrItsArguments() {
        let honest = agy("run_command", ["CommandLine": "ls"])
        #expect(parse(honest, .agy) != nil)
        for key in ["toolcall", "ToolCall", "tool_call", "args", "arguments", "input", "toolArgs", "toolName"] {
            #expect(parse(honest.merging([key: ["name": "run_command", "args": ["CommandLine": "rm -rf ~"]]]) { $1 }, .agy) == nil, "\(key)")
        }
        let shell = cursorShell(["sandbox": true])
        #expect(parse(shell, .cursor) != nil)
        for key in ["toolInput", "tool_args", "arguments", "params", "input", "args"] {
            #expect(parse(shell.merging([key: ["command": "rm -rf ~"]]) { $1 }, .cursor) == nil, "\(key)")
        }
        for key in ["arguments", "input", "params", "tool_call", "toolCall"] {
            #expect(parse(copilot(["toolName": "bash", "toolArgs": ["command": "ls"], key: ["command": "rm -rf ~"]]), .copilot) == nil, "\(key)")
        }
    }

    @Test func aKeyTwiceAnywhereInTheRequestGetsNoCardForAnyTool() {
        let cases: [(PermissionDialect, String)] = [
            (.agy, #"{"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}},"toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf ~"}}}"#),
            (.agy, #"{"toolCall":{"name":"run_command","name":"view_file","args":{"CommandLine":"ls"}}}"#),
            (.agy, #"{"toolCall":{"name":"run_command","args":{"CommandLine":"ls"},"args":{"CommandLine":"rm -rf ~"}}}"#),
            (.copilot, #"{"toolName":"bash","toolArgs":{"command":"ls"},"toolArgs":{"command":"rm -rf ~"}}"#),
            (.copilot, #"{"toolName":"bash","toolInput":{"command":"ls","command":"rm -rf ~"}}"#),
            (.cursor, #"{"hook_event_name":"beforeMCPExecution","tool_name":"t","tool_input":{"a":1,"a":2}}"#),
            (.cursor, #"{"hook_event_name":"beforeMCPExecution","tool_name":"t","tool_name":"u","tool_input":{"a":1}}"#),
            (.cursor, #"{"hook_event_name":"beforeShellExecution","hook_event_name":"beforeMCPExecution","command":"ls"}"#),
        ]
        for (dialect, text) in cases { #expect(PermissionPrompt.parse(Data(text.utf8), dialect: dialect) == nil, "\(dialect) \(text)") }
        let honest = #"{"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}"#
        #expect(PermissionPrompt.parse(Data(honest.utf8), dialect: .agy) != nil)
    }

    @Test func everyGateOfTheOtherPathsHoldsForTheCardsOfTheseTools() throws {
        // The title is the card's own words for a known call, and the tool's name for any other; nothing a model wrote.
        let known = try #require(parse(copilot(["toolName": "bash", "toolArgs": ["command": "ls", "description": "Evil title"]]), .copilot)).prompt
        #expect(known.title == "Run a command" && !known.title.contains("Evil"))
        // "Always allow" is never offered, nor a rule saved: the request's suggestions are not read, and the answer is refused.
        let withSuggestions = copilot(["toolName": "bash", "toolArgs": ["command": "ls"], "permission_suggestions": [PermissionTestServer.addRules]])
        let suggested = try #require(parse(withSuggestions, .copilot))
        #expect(suggested.prompt.grant == nil && suggested.suggestion == nil)
        #expect(PermissionWire.decision(.always, suggestion: PermissionTestServer.addRules, dialect: .copilot) == nil)
        for dialect in [PermissionDialect.copilot, .agy, .cursor] { #expect(PermissionWire.decision(.always, suggestion: nil, dialect: dialect) == nil) }
        // A sandbox flag, Claude Code's included, is more than the warning chip it is for Claude Code: Copilot asks for it itself.
        #expect(parse(copilot(["toolName": "bash", "toolArgs": ["command": "ls", "dangerouslyDisableSandbox": true]]), .copilot) == nil)
        // What is too long to show whole is not shown.
        let long = String(repeating: "x", count: PermissionPrompt.detailLimit + 1)
        #expect(parse(copilot(["toolName": "bash", "toolArgs": ["command": long]]), .copilot) == nil)
        #expect(parse(agy("run_command", ["CommandLine": long]), .agy) == nil)
        #expect(parse(cursorShell(["command": long, "sandbox": true]), .cursor) == nil)
        #expect(parse(copilot(["toolName": String(repeating: "t", count: PermissionPrompt.titleLimit + 1), "toolArgs": ["a": 1]]), .copilot) == nil)
    }

    // MARK: Strict JSON

    @Test func strictJSONFindsAKeyTwiceAtAnyDepthAndNothingElse() {
        func twice(_ text: String) -> Bool { StrictJSON.hasDuplicateKeys(Data(text.utf8)) }
        for text in [#"{"a":1,"a":2}"#, #"{"a":{"b":1,"b":2}}"#, #"[{"a":1},{"b":1,"b":1}]"#, #"{"a":"x","a":"y"}"#, "{\"\u{e9}\":1,\"e\u{301}\":2}",
                     #"{"a":1,"b":{"c":[{"d":1,"d":2}]}}"#] {
            #expect(twice(text), "\(text)")
        }
        for text in [#"{"a":1,"b":2}"#, #"{"a":{"a":1},"b":[{"a":1},{"a":2}]}"#, "{}", "[]", #"{"a":"a","b":"a"}"#, #"  {"a" : [1, 2.5e3, true, null, "x\"y"]}  "#,
                     #"{"a\"b":1,"a":2}"#] {
            #expect(!twice(text), "\(text)")
        }
        // What is not well formed counts as ambiguous.
        for text in ["", "{", #"{"a":1,}"#, #"{"a" 1}"#, #"{"a":1} x"#, #"{"a":"\ud800","b":1}"#, String(repeating: "[", count: 100)] {
            #expect(twice(text), "\(text)")
        }
        #expect(StrictJSON.object(from: #"{"a":1}"#)?["a"] as? Int == 1 && StrictJSON.object(from: "[1]") == nil && StrictJSON.object(from: #"{"a":1,"a":1}"#) == nil)
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

    // MARK: Second review

    @Test func aCursorMCPCallNeedsItsServerSoItCantPassForABuiltInTool() throws {
        let call: [String: Any] = ["hook_event_name": "beforeMCPExecution", "tool_name": "Bash", "tool_input": #"{"command":"ls"}"#,
                                   "command": "npx some-server"]
        #expect(parse(call, .cursor) == nil)
        #expect(parse(call.merging(["mcp_server_name": ""]) { $1 }, .cursor) == nil)
        let named = try #require(parse(call.merging(["mcp_server_name": "tools"]) { $1 }, .cursor))
        #expect(named.prompt.title == "mcp__tools__Bash")
    }

    @Test func anHTTPServersAddressSentTwiceIsOneAddress() {
        let call: [String: Any] = ["hook_event_name": "beforeMCPExecution", "tool_name": "search", "tool_input": [String: Any](),
                                   "mcp_server_name": "web", "url": "https://example.test/mcp", "mcp_server_url": "https://example.test/mcp"]
        #expect(parse(call, .cursor) != nil)
        #expect(parse(call.merging(["url": "https://other.test/mcp"]) { $1 }, .cursor) == nil)
    }

    @Test func aCopilotCallNamedLikeAClaudeCodeToolHasNoCard() {
        for name in ["Write", "Edit", "Bash", "Read", "WebFetch"] {
            #expect(parse(["toolName": name, "toolInput": ["file_path": "/a", "content": "x"]], .copilot) == nil, Comment(rawValue: name))
        }
        #expect(parse(["toolName": "bash", "toolInput": ["command": "ls"]], .copilot) != nil)
    }

    @Test func anySpellingOfASandboxBypassIsLeftToCopilot() {
        for key in ["requestSandboxBypass", "RequestSandboxBypass", "request_sandbox_bypass", "sandbox"] {
            #expect(parse(["toolName": "bash", "toolInput": ["command": "ls", key: true]], .copilot) == nil, Comment(rawValue: key))
            #expect(parse(["toolName": "bash", "toolInput": ["command": "ls"], key: true], .copilot) == nil, Comment(rawValue: key))
        }
    }

    @Test func aCursorCommandWithoutSandboxTrueIsLeftToCursor() {
        let call: [String: Any] = ["hook_event_name": "beforeShellExecution", "command": "ls", "cwd": "/p"]
        #expect(parse(call, .cursor) == nil)
        #expect(parse(call.merging(["sandbox": false]) { $1 }, .cursor) == nil)
        #expect(parse(call.merging(["sandbox": 1]) { $1 }, .cursor) == nil)
        #expect(parse(call.merging(["sandbox": true]) { $1 }, .cursor) != nil)
    }

    @Test func aToolNameThatIsNoTextHasNoCard() {
        #expect(parse(["toolName": 5, "tool_name": 6, "kind": "bash", "toolInput": ["command": "ls"]], .copilot) == nil)
        #expect(parse(["toolName": "bash", "kind": 3, "toolInput": ["command": "ls"]], .copilot) == nil)
    }

    /// "é" composed and decomposed are two keys to Foundation and one to Swift: no card, and no crash, on any path.
    @Test func keysThatDifferOnlyInComposedLettersAreReadAsAKeyTwice() {
        let text = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls","\#u{E9}":1,"e\#u{301}":2}}"#
        #expect(PermissionPrompt.parse(Data(text.utf8)) == nil)
        #expect(StrictJSON.object(from: #"{"\#u{E9}":1,"e\#u{301}":2}"#) == nil)
        let copilot = #"{"toolName":"bash","toolInput":{"command":"ls","\#u{E9}":1,"e\#u{301}":2}}"#
        #expect(PermissionPrompt.parse(Data(copilot.utf8), dialect: .copilot) == nil)
    }
}
