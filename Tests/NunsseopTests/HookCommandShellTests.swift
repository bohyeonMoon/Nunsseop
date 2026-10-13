import Foundation
import Testing
@testable import Nunsseop

/// A shell run with a stand-in `curl` that records what it was given, a stand-in `prev.sh` (the user's own notify
/// command), a scratch home holding the notify token, and a pinned `__CFBundleIdentifier`.
private struct ShellRun {
    var args: [String] = []
    var body = ""
    var curlCalls = 0
    /// The arguments `prev.sh` got, nil when it didn't run.
    var previousArgs: [String]?
    var stdout = ""
    var status: Int32 = 0
    var dir: URL

    /// What curl is given for the header: the file holding it, never the token.
    var authArgument: String { "@" + dir.path + "/Library/Application Support/Nunsseop/notify-auth" }

    /// - arguments: what to give `/bin/sh`, given the scratch folder.
    /// - environment: extra variables; the inherited ones are not passed on.
    static func run(_ arguments: (URL) throws -> [String], stdin: String = "", environment: [String: String] = [:],
                    curlExit: Int32 = 0) throws -> ShellRun {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent("nunsseop-test-\(UUID().uuidString.prefix(8))")
        try fileManager.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }
        let support = dir.appendingPathComponent("Library/Application Support/Nunsseop")
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try "tok\n".write(to: support.appendingPathComponent("notify-token"), atomically: true, encoding: .utf8)
        try "Authorization: Bearer tok\n".write(to: support.appendingPathComponent("notify-auth"), atomically: true, encoding: .utf8)
        let curl = dir.appendingPathComponent("bin/curl")
        try StubTool.write("""
        #!/bin/sh
        echo x >> "\(dir.path)/calls"
        for arg; do printf '%s\\n' "$arg"; done > "\(dir.path)/args"
        cat > "\(dir.path)/body"
        echo LEAK
        exit \(curlExit)
        """, to: curl)
        let previous = dir.appendingPathComponent("prev.sh")
        try StubTool.write("""
        #!/bin/sh
        for arg; do printf '%s\\n' "$arg"; done > "\(dir.path)/prev-args"
        """, to: previous)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = try arguments(dir)
        process.currentDirectoryURL = dir
        process.environment = ["HOME": dir.path, "PATH": "\(dir.path)/bin:/usr/bin:/bin"].merging(environment) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        func text(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
        func lines(_ name: String) -> [String]? { text(name).map { Array($0.components(separatedBy: "\n").dropLast()) } }
        var result = ShellRun(dir: dir)
        result.args = lines("args") ?? []
        result.body = text("body") ?? ""
        result.curlCalls = lines("calls")?.count ?? 0
        result.previousArgs = lines("prev-args")
        result.stdout = String(data: out, encoding: .utf8) ?? ""
        result.status = process.terminationStatus
        return result
    }
}

private func json(_ object: [String: String]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), encoding: .utf8)!
}

struct AgentHookShellTests {
    private func run(_ stdin: String, environment: [String: String] = ["__CFBundleIdentifier": "com.x"], curlExit: Int32 = 0) throws -> ShellRun {
        try ShellRun.run({ _ in ["-c", NotifyServer.agentHookCommand] }, stdin: stdin, environment: environment, curlExit: curlExit)
    }

    @Test func sendsTheEventAsHeadersOnly() throws {
        let sent = try run(json(["session_id": "abc-123", "hook_event_name": "Stop", "notification_type": "permission_prompt",
                                 "prompt": "secret prompt", "cwd": "/Users/me/secret"]))
        #expect(sent.args == [
            "-s", "-m", "1", "--connect-timeout", "1", "-X", "POST", "http://127.0.0.1:\(NotifyServer.port)/agent", "-d", "",
            "-H", sent.authArgument, "-H", "X-Session: abc-123", "-H", "X-Event: Stop",
            "-H", "X-Type: permission_prompt", "-H", "X-Subagent: ", "-H", "X-App: com.x",
            "-H", "X-Herdr: ", "-H", "X-Muxy: ", "-H", "X-Cmux: ", "-H", "X-Mux: ", "-H", "X-Wezterm: ", "-H", "X-Wezterm-Socket: ", "-H", "X-Kitty: ", "-H", "X-Kitty-Socket: ", "-H", "X-Iterm: ", "-H", "X-Orca: ", "-H", "X-Background: ", "-H", "X-Pid: \(getpid())", "-H", "X-Background-Tasks: ",
        ])
        #expect(sent.curlCalls == 1)
        #expect(sent.stdout.isEmpty)
        #expect(sent.status == 0)
    }

    @Test func herdrAndBackgroundSessionsAreFlagged() throws {
        let stdin = json(["session_id": "s", "hook_event_name": "UserPromptSubmit"])
        let herdr = try run(stdin, environment: ["__CFBundleIdentifier": "com.x", "HERDR_PANE_ID": "1"])
        #expect(herdr.args.contains("X-Herdr: 1") && herdr.args.contains("X-Background: "))
        let background = try run(stdin, environment: ["__CFBundleIdentifier": "com.x", "CLAUDE_JOB_DIR": "/tmp/job"])
        #expect(background.args.contains("X-Background: 1") && background.args.contains("X-Herdr: "))
        let unset = try run(stdin, environment: [:])
        #expect(unset.args.contains("X-App: "))
    }

    @Test func theTerminalsInputTargetIsSentAsHeadersForBothTools() throws {
        let stdin = json(["session_id": "s", "hook_event_name": "Stop"])
        let environment = ["__CFBundleIdentifier": "com.x", "MUXY_SESSION_ID": "1978299613479001934",
                           "CMUX_SURFACE_ID": "6F1B2C3D-0000-4000-8000-000000000001"]
        for command in [NotifyServer.agentHookCommand, NotifyServer.agentHookCommand(for: .codex)] {
            let sent = try ShellRun.run({ _ in ["-c", command] }, stdin: stdin, environment: environment)
            #expect(sent.args.contains("X-Muxy: 1978299613479001934"))
            #expect(sent.args.contains("X-Cmux: 6F1B2C3D-0000-4000-8000-000000000001"))
            #expect(sent.stdout.isEmpty && sent.status == 0)
        }
    }

    @Test func theIdsOfWezTermKittyAndITerm2AreSentForBothTools() throws {
        let stdin = json(["session_id": "s", "hook_event_name": "Stop"])
        let environment = ["__CFBundleIdentifier": "com.x", "WEZTERM_PANE": "7", "WEZTERM_UNIX_SOCKET": "/tmp/wezterm-gui-sock-1", "KITTY_WINDOW_ID": "3",
                           "KITTY_LISTEN_ON": "unix:/tmp/kitty-1234", "ITERM_SESSION_ID": "w0t0p0:6F1B2C3D-0000-4000-8000-000000000001"]
        for command in [NotifyServer.agentHookCommand, NotifyServer.agentHookCommand(for: .codex)] {
            let sent = try ShellRun.run({ _ in ["-c", command] }, stdin: stdin, environment: environment)
            #expect(sent.args.contains("X-Wezterm: 7") && sent.args.contains("X-Kitty: 3"))
            #expect(sent.args.contains("X-Wezterm-Socket: /tmp/wezterm-gui-sock-1"))
            #expect(sent.args.contains("X-Kitty-Socket: unix:/tmp/kitty-1234"))
            #expect(sent.args.contains("X-Iterm: w0t0p0:6F1B2C3D-0000-4000-8000-000000000001"))
            #expect(sent.stdout.isEmpty && sent.status == 0)
        }
    }

    @Test func theOrcaPaneKeyIsSentAsItIsForBothTools() throws {
        let stdin = json(["session_id": "s", "hook_event_name": "Stop"])
        let key = "7d1e6f0a-4b2c-4a85-9c3d-0e5f1a2b3c4d:2c9a0f1e-8b7d-4e6a-a1b2-c3d4e5f60718"
        for command in [NotifyServer.agentHookCommand, NotifyServer.agentHookCommand(for: .codex)] {
            let sent = try ShellRun.run({ _ in ["-c", command] }, stdin: stdin, environment: ["__CFBundleIdentifier": "com.x", "ORCA_PANE_KEY": key])
            #expect(sent.args.contains("X-Orca: \(key)"))
            // Nothing else of Orca's environment is sent: the hook endpoint's port and token are not Nunsseop's to use.
            #expect(sent.args.allSatisfy { !$0.contains("ORCA_AGENT_HOOK") })
            #expect(sent.stdout.isEmpty && sent.status == 0)
        }
    }

    @Test func runningInsideTmuxZellijOrScreenIsSentForBothTools() throws {
        let stdin = json(["session_id": "s", "hook_event_name": "Stop"])
        for command in [NotifyServer.agentHookCommand, NotifyServer.agentHookCommand(for: .codex)] {
            for variable in ["TMUX", "ZELLIJ", "STY"] {
                let sent = try ShellRun.run({ _ in ["-c", command] }, stdin: stdin,
                                            environment: ["__CFBundleIdentifier": "com.x", variable: "/tmp/x,1,0"])
                #expect(sent.args.contains("X-Mux: 1"), "\(variable)")
            }
            let outside = try ShellRun.run({ _ in ["-c", command] }, stdin: stdin, environment: ["__CFBundleIdentifier": "com.x"])
            #expect(outside.args.contains("X-Mux: "))
        }
    }

    @Test func sessionStartSendsItsProcessAndPrintsNothing() throws {
        let sent = try run(json(["session_id": "s", "hook_event_name": "SessionStart", "source": "resume"]))
        #expect(sent.args.contains("X-Event: SessionStart") && sent.args.contains("X-Pid: \(getpid())"))
        // SessionStart's stdout goes into Claude's context.
        #expect(sent.stdout.isEmpty && sent.status == 0)
    }

    @Test func aStopSendsHowManyBackgroundTasksItListsAndOnlyTheCount() throws {
        let tasks = #"[{"id":"a1","type":"subagent","status":"running","description":"secret plan"},{"id":"b2","type":"shell","status":"running","command":"rm -rf secret"}]"#
        let two = try run(#"{"session_id":"s","hook_event_name":"Stop","background_tasks":\#(tasks)}"#)
        #expect(two.args.contains("X-Background-Tasks: 2") && two.args.last == "X-Background-Tasks: 2")
        #expect(!two.args.joined().contains("secret") && two.body.isEmpty)
        // An empty list is a 0, which tells the hand-back's Stop that everything is done; no list and no key send nothing.
        let none = try run(#"{"session_id":"s","hook_event_name":"Stop","background_tasks":[]}"#)
        #expect(none.args.contains("X-Background-Tasks: 0"))
        let absent = try run(json(["session_id": "s", "hook_event_name": "Stop"]))
        #expect(absent.args.contains("X-Background-Tasks: "))
        // Twelve tasks keep every digit of the count.
        let many = try run(#"{"session_id":"s","hook_event_name":"Stop","background_tasks":[\#(Array(repeating: "{}", count: 12).joined(separator: ","))]}"#)
        #expect(many.args.contains("X-Background-Tasks: 12"))
        // Whatever the value, only characters of the safe set leave, and nothing is run.
        let text = try run(json(["session_id": "s", "hook_event_name": "Stop", "background_tasks": "3$(touch pwn)"]))
        #expect(text.args.contains("X-Background-Tasks: 3touchpwn"))
        #expect(!FileManager.default.fileExists(atPath: text.dir.appendingPathComponent("pwn").path))
        #expect(two.status == 0 && two.stdout.isEmpty)
    }

    @Test func aSubagentCallCarriesItsId() throws {
        let sent = try run(json(["session_id": "s", "hook_event_name": "Stop", "agent_id": "agent-1"]))
        #expect(sent.args.contains("X-Subagent: agent-1"))
    }

    @Test func idsAreTrimmedToSafeCharactersAndNeverRun() throws {
        let sent = try run(json(["session_id": "a$(touch pwn)b;`touch pwn2`\r\nX-Evil: 1", "hook_event_name": "Stop"]))
        #expect(sent.args.contains("X-Session: atouchpwnbtouchpwn2X-Evil1"))
        #expect(!FileManager.default.fileExists(atPath: sent.dir.appendingPathComponent("pwn").path))
        #expect(!FileManager.default.fileExists(atPath: sent.dir.appendingPathComponent("pwn2").path))
        let long = try run(json(["session_id": String(repeating: "a", count: 100), "hook_event_name": "Stop"]))
        #expect(long.args.contains("X-Session: " + String(repeating: "a", count: 64)))
    }

    @Test func emptyOrBrokenInputStillCallsWithEmptyHeaders() throws {
        for stdin in ["", "not json", "[1]"] {
            let sent = try run(stdin)
            #expect(sent.curlCalls == 1, "\(stdin)")
            #expect(sent.args.contains("X-Session: ") && sent.args.contains("X-Event: ") && sent.args.contains("X-Type: "), "\(stdin)")
            #expect(sent.status == 0 && sent.stdout.isEmpty)
        }
    }

    @Test func aClosedNunsseopCostsTheSessionNothing() throws {
        let sent = try run(json(["session_id": "s", "hook_event_name": "Stop"]), curlExit: 7)
        #expect(sent.status == 0)
        #expect(sent.stdout.isEmpty)
    }
}

struct CodexAgentHookShellTests {
    private func run(_ stdin: String, environment: [String: String] = ["__CFBundleIdentifier": "com.x"], curlExit: Int32 = 0) throws -> ShellRun {
        try ShellRun.run({ _ in ["-c", NotifyServer.agentHookCommand(for: .codex)] }, stdin: stdin, environment: environment, curlExit: curlExit)
    }

    /// What Codex 0.155 writes to a PermissionRequest hook's stdin (its schema), with the parts that must never leave.
    private let permissionRequest = #"""
        {"session_id":"019e5b2c-7a41-7c10-8d3e-2f6a9c1b4e07","turn_id":"turn-1","transcript_path":"/Users/me/.codex/sessions/s.jsonl",
         "cwd":"/Users/me/secret","hook_event_name":"PermissionRequest","model":"gpt-5.5","permission_mode":"default",
         "tool_name":"Bash","tool_input":{"command":"rm -rf secret","description":"secret plan"}}
        """#

    @Test func sendsTheEventAsHeadersOnlyAndNamesCodex() throws {
        let sent = try run(permissionRequest)
        #expect(sent.args == [
            "-s", "-m", "1", "--connect-timeout", "1", "-X", "POST", "http://127.0.0.1:\(NotifyServer.port)/agent", "-d", "",
            "-H", sent.authArgument, "-H", "X-Session: 019e5b2c-7a41-7c10-8d3e-2f6a9c1b4e07",
            "-H", "X-Event: PermissionRequest", "-H", "X-Type: ", "-H", "X-Subagent: ", "-H", "X-App: com.x",
            "-H", "X-Herdr: ", "-H", "X-Muxy: ", "-H", "X-Cmux: ", "-H", "X-Mux: ", "-H", "X-Wezterm: ", "-H", "X-Wezterm-Socket: ", "-H", "X-Kitty: ", "-H", "X-Kitty-Socket: ", "-H", "X-Iterm: ", "-H", "X-Orca: ", "-H", "X-Background: ", "-H", "X-Pid: \(getpid())",
            "-H", "X-Agent: codex",
        ])
        #expect(sent.body.isEmpty)
        #expect(!sent.args.joined().contains("secret") && !sent.args.joined().contains("rm -rf") && !sent.args.joined().contains("gpt"))
        #expect(sent.curlCalls == 1 && sent.stdout.isEmpty && sent.status == 0)
    }

    @Test func eachEventOfTheMappingReachesTheServerAsTheEventTheCountReads() throws {
        for (event, action) in [("UserPromptSubmit", AgentAction.working), ("PermissionRequest", .needsInput), ("Stop", .finished),
                                ("Interrupt", .idle), ("SessionEnd", .remove)] {
            let sent = try run(json(["session_id": "s-1", "hook_event_name": event, "turn_id": "t", "prompt": "do it"]))
            var headers: [String: String] = [:]
            for (flag, header) in zip(sent.args, sent.args.dropFirst()) where flag == "-H" {
                guard let colon = header.firstIndex(of: ":") else { continue }
                headers[header[..<colon].lowercased()] = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            #expect(AgentHook.event(headers: headers)
                    == AgentEvent(session: "s-1", action: action, app: "com.x", inHerdr: false, agent: .codex, pid: getpid()), "\(event)")
        }
    }

    @Test func aSubagentCallCarriesItsIdAndHerdrIsFlagged() throws {
        let sub = try run(json(["session_id": "s", "hook_event_name": "PermissionRequest", "agent_id": "agent-7"]))
        #expect(sub.args.contains("X-Subagent: agent-7"))
        let herdr = try run(json(["session_id": "s", "hook_event_name": "Stop"]), environment: ["__CFBundleIdentifier": "com.x", "HERDR_PANE_ID": "1"])
        #expect(herdr.args.contains("X-Herdr: 1") && herdr.args.contains("X-Agent: codex"))
    }

    @Test func aClosedNunsseopOrBrokenInputCostsTheSessionNothing() throws {
        for stdin in ["", "not json"] {
            let sent = try run(stdin)
            #expect(sent.curlCalls == 1 && sent.status == 0 && sent.stdout.isEmpty, "\(stdin)")
        }
        let closed = try run(json(["session_id": "s", "hook_event_name": "Stop"]), curlExit: 7)
        #expect(closed.status == 0 && closed.stdout.isEmpty)
    }
}

struct NoticeHookShellTests {
    private func run(_ environment: [String: String] = [:], curlExit: Int32 = 0) throws -> ShellRun {
        try ShellRun.run({ _ in ["-c", NotifyServer.hookCommand(title: "Claude Code")] },
                         stdin: json(["message": "Claude needs your permission"]),
                         environment: ["__CFBundleIdentifier": "com.apple.Terminal"].merging(environment) { $1 }, curlExit: curlExit)
    }

    @Test func sendsTheMessageAsTheBody() throws {
        let sent = try run()
        #expect(sent.args == [
            "-s", "-m", "2", "-X", "POST", "http://127.0.0.1:\(NotifyServer.port)/notify",
            "-H", sent.authArgument, "-H", "X-Title: Claude Code", "-H", "X-App: com.apple.Terminal",
            "-H", "X-Background: ", "--data-binary", "@-",
        ])
        #expect(sent.body == "Claude needs your permission\n")
        #expect(sent.stdout.isEmpty)
        #expect(sent.status == 0)
    }

    @Test func aBackgroundSessionIsFlagged() throws {
        let sent = try run(["CLAUDE_JOB_DIR": "/tmp/job"])
        #expect(sent.args.contains("X-Background: 1"))
        #expect(sent.args.contains("X-App: com.apple.Terminal"))
    }

    @Test func aFailingCurlDoesNotFailTheHook() throws {
        let sent = try run(curlExit: 7)
        #expect(sent.status == 0 && sent.stdout.isEmpty)
    }

    @Test func geminiGetsItsOwnTitle() throws {
        let sent = try ShellRun.run({ _ in ["-c", NotifyServer.hookCommand(title: "Gemini CLI")] },
                                    stdin: json(["message": "m"]), environment: ["__CFBundleIdentifier": "com.x"])
        #expect(sent.args.contains("X-Title: Gemini CLI"))
    }
}

struct CodexNotifyScriptTests {
    private let payload = #"{"type":"agent-turn-complete","last-assistant-message":"All done"}"#

    /// Runs the shipped wrapper; `PREVIOUS` in `arguments` stands for the user's own notify command.
    private func run(_ arguments: [String], curlExit: Int32 = 0) throws -> ShellRun {
        try ShellRun.run({ dir in
            let script = dir.appendingPathComponent("codex-notify.sh")
            try CodexNotify.script.write(to: script, atomically: true, encoding: .utf8)
            return [script.path] + arguments.map { $0 == "PREVIOUS" ? dir.appendingPathComponent("prev.sh").path : $0 }
        }, environment: ["__CFBundleIdentifier": "com.x"], curlExit: curlExit)
    }

    @Test func showsTheTurnAndThenRunsTheCommandThatWasThereBefore() throws {
        let sent = try run(["PREVIOUS", "--flag", payload])
        #expect(sent.args == [
            "-s", "-m", "2", "-X", "POST", "http://127.0.0.1:\(NotifyServer.port)/notify",
            "-H", sent.authArgument, "-H", "X-Title: Codex", "-H", "X-App: com.x", "--data-binary", "@-",
        ])
        #expect(sent.body == "All done\n")
        #expect(sent.previousArgs == ["--flag", payload])
        #expect(sent.status == 0 && sent.stdout.isEmpty)
    }

    @Test func withNothingBeforeItOnlyShowsTheTurn() throws {
        let sent = try run([payload])
        #expect(sent.curlCalls == 1 && sent.body == "All done\n")
        #expect(sent.previousArgs == nil)
        #expect(sent.status == 0)
    }

    @Test func aPayloadWithoutAMessageStillRunsTheCommandBefore() throws {
        for odd in [#"{"type":"agent-turn-complete"}"#, "not json", ""] {
            let sent = try run(["PREVIOUS", odd])
            #expect(sent.curlCalls == 1 && sent.body.isEmpty, "\(odd)")
            #expect(sent.previousArgs == [odd], "\(odd)")
            #expect(sent.status == 0)
        }
    }

    @Test func aFailingCurlDoesNotStopTheCommandBefore() throws {
        let sent = try run(["PREVIOUS", "--flag", payload], curlExit: 7)
        #expect(sent.previousArgs == ["--flag", payload])
        #expect(sent.status == 0)
        let alone = try run([payload], curlExit: 7)
        #expect(alone.status == 0)
    }
}
