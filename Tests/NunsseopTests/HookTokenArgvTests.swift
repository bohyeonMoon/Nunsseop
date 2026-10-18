import Foundation
import Testing
@testable import Nunsseop

/// The commands and scripts of 0.28 and before, which gave curl the token on its command line, as they were installed.
enum TokenInArgvFixtures {
    static let tokenFile = "$HOME/Library/Application Support/Nunsseop/notify-token"

    static func notice(title: String, port: UInt16 = NotifyServer.port) -> String {
        "plutil -extract message raw -o - - 2>/dev/null | curl -s -m 2 -X POST http://127.0.0.1:\(port)/notify "
            + "-H \"Authorization: Bearer $(cat \"\(tokenFile)\")\" "
            + "-H 'X-Title: \(title)' -H \"X-App: $__CFBundleIdentifier\" -H \"X-Background: ${CLAUDE_JOB_DIR:+1}\" --data-binary @- >/dev/null || true"
    }

    static func agent(codex: Bool, port: UInt16 = NotifyServer.port) -> String {
        "in=$(cat); k() { printf '%s' \"$in\" | plutil -extract \"$1\" raw -o - - 2>/dev/null | tr -cd 'A-Za-z0-9_.-' | cut -c1-64; }; "
            + "curl -s -m 1 --connect-timeout 1 -X POST http://127.0.0.1:\(port)/agent -d '' "
            + "-H \"Authorization: Bearer $(cat \"\(tokenFile)\")\" "
            + "-H \"X-Session: $(k session_id)\" -H \"X-Event: $(k hook_event_name)\" -H \"X-Type: $(k notification_type)\" "
            + "-H \"X-Subagent: $(k agent_id)\" -H \"X-App: $__CFBundleIdentifier\" -H \"X-Herdr: ${HERDR_PANE_ID:+1}\" "
            + "-H \"X-Background: ${CLAUDE_JOB_DIR:+1}\" "
            + (codex ? "-H 'X-Agent: codex' " : "")
            + ">/dev/null 2>&1 || true"
    }

    /// "Copy command for scripts", as a user pasted it into a script of their own.
    static func script(port: UInt16 = NotifyServer.port) -> String {
        "curl -s -m 2 -X POST http://127.0.0.1:\(port)/notify "
            + "-H \"Authorization: Bearer $(cat \"\(tokenFile)\")\" "
            + "-H 'X-Title: Script' --data-binary 'Done'"
    }

    static func codexScript(port: UInt16 = NotifyServer.port) -> String {
        """
        #!/bin/sh
        # Added by Nunsseop. Codex passes its event JSON as the last argument. This shows the turn in the notch,
        # then runs the notify command that was set before Nunsseop, if any, with the same arguments.
        for payload; do :; done
        token=$(cat "$HOME/Library/Application Support/Nunsseop/notify-token" 2>/dev/null)
        printf '%s' "$payload" | plutil -extract last-assistant-message raw -o - - 2>/dev/null \\
            | curl -s -m 2 -X POST http://127.0.0.1:\(port)/notify -H "Authorization: Bearer $token" \\
                -H 'X-Title: Codex' -H "X-App: $__CFBundleIdentifier" --data-binary @- >/dev/null 2>&1
        [ $# -gt 1 ] && exec "$@"
        exit 0

        """
    }

    /// The lines of the bell script that carried the token; the rest of it is the same as today's.
    static func terminalScript(port: UInt16 = NotifyServer.port) -> String {
        """
        #!/bin/sh
        # Added by Nunsseop: shows bells from terminal panes in the notch.
        token=$(cat "$HOME/Library/Application Support/Nunsseop/notify-token" 2>/dev/null)
        app=$(printf '%s' "$1" | tr -cd '[:alnum:]._-' | cut -c1-40)
        agent=$(printf '%s' "$4" | tr -cd '[:alnum:]._-' | cut -c1-40)
        target=$(printf '%s' "$5" | tr -cd '[:alnum:]%@._-' | cut -c1-40)
        bundle=$(printf '%s' "$__CFBundleIdentifier" | tr -cd '[:alnum:].-' | cut -c1-80)
        if [ -n "$2" ] && [ -n "$3" ]; then where="$2 · $3"; else where="$2$3"; fi
        printf '%s' "$where" | curl -s -m 2 -X POST http://127.0.0.1:\(port)/notify \\
            -H "Authorization: Bearer $token" -H "X-Title: ${agent:-$app}" -H "X-Agent: $agent" \\
            -H "X-App: $bundle" -H "X-Target: ${target:+$app:$target}" --data-binary @- >/dev/null 2>&1
        exit 0

        """
    }
}

/// Every command Nunsseop gives a tool, as a shell line.
private enum Shape: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case notice, gemini, agentClaude, agentCodex, script, codexNotify, terminalBell

    var testDescription: String { rawValue }

    var stdin: String {
        switch self {
        case .notice, .gemini: #"{"message":"Needs you"}"#
        case .agentClaude, .agentCodex: #"{"session_id":"s-1","hook_event_name":"Stop"}"#
        case .script, .codexNotify, .terminalBell: ""
        }
    }

    /// The line `/bin/sh -c` runs, aimed at `port`; the scripts are written into `dir` first.
    func command(in dir: URL, port: UInt16) throws -> String {
        switch self {
        case .notice: return NotifyServer.hookCommand(title: "Claude Code", port: port)
        case .gemini: return NotifyServer.hookCommand(title: "Gemini CLI", port: port)
        case .agentClaude: return NotifyServer.agentHookCommand(for: .claude, port: port)
        case .agentCodex: return NotifyServer.agentHookCommand(for: .codex, port: port)
        case .script: return NotifyServer.scriptCommand(port: port)
        case .codexNotify:
            let file = dir.appendingPathComponent("codex-notify.sh")
            try CodexNotify.script(port: port).write(to: file, atomically: true, encoding: .utf8)
            return "/bin/sh '\(file.path)' '{\"type\":\"agent-turn-complete\",\"last-assistant-message\":\"All done\"}'"
        case .terminalBell:
            let file = dir.appendingPathComponent("terminal-notify.sh")
            let script = TerminalBell.script.replacingOccurrences(of: "127.0.0.1:\(NotifyServer.port)/", with: "127.0.0.1:\(port)/")
            TerminalBell.install(at: file, script: script)
            return "/bin/sh '\(file.path)' tmux work api ''"
        }
    }
}

/// A scratch home with a token (and, written the way the app writes it, the header file) and a PATH whose `curl` is `body`.
private struct Sandbox {
    let home: ScratchHome
    var dir: URL { home.url }
    let token: String

    init(token: String, curl body: String) throws {
        self.token = token
        home = try ScratchHome(token: token)
        NotifyIntegration.$homeOverride.withValue(home.url) { NotifyServer.syncAuthHeader() }
        let bin = home.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let curl = bin.appendingPathComponent("curl")
        try StubTool.write("#!/bin/sh\n" + body, to: curl)
    }

    var authFile: URL { dir.appendingPathComponent("Library/Application Support/Nunsseop/notify-auth") }

    func text(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

    /// Runs `command` as a tool does, and waits for it.
    func run(_ command: String, stdin: String) async throws -> (stdout: String, status: Int32) {
        let process = try HookProcess(command: command, home: dir, stdin: Data(stdin.utf8), path: "\(dir.path)/bin:/usr/bin:/bin",
                                      environment: ["__CFBundleIdentifier": "com.x"])
        return try #require(await process.finish())
    }
}

/// A stand-in `curl` that records its arguments and environment, and the command line of every process on the machine at that moment.
private let snapshotCurl = """
    D="$HOME/seen"; mkdir -p "$D"
    for arg; do printf '%s\\n' "$arg"; done > "$D/args"
    env > "$D/env"
    ps -axww -o command= > "$D/ps"
    for arg; do case "$arg" in @/*) cat "${arg#@}" > "$D/header";; esac; done
    cat > "$D/body"
    echo x >> "$D/calls"
    """

struct HookTokenArgvTests {
    /// A token of its own for each run: the tests run side by side, and one that leaks on purpose must not show in another's snapshot.
    static func freshToken() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased() }

    @Test(arguments: Shape.allCases) fileprivate func noCommandPutsTheTokenInAnyProcessesArgumentsOrEnvironment(shape: Shape) async throws {
        let token = Self.freshToken()
        let box = try Sandbox(token: token, curl: snapshotCurl)
        let sent = try await box.run(try shape.command(in: box.dir, port: NotifyServer.port), stdin: shape.stdin)
        #expect(sent.status == 0 && sent.stdout.isEmpty)
        #expect(box.text("seen/calls") == "x\n")
        let args = try #require(box.text("seen/args"))
        #expect(!args.contains(token) && !args.contains("Bearer"), "curl's arguments: \(args)")
        #expect(args.contains("@\(box.authFile.path)\n"), "\(args)")
        #expect(!(box.text("seen/env") ?? "").contains(token), "curl's environment")
        // Every process on the machine at the moment curl ran, the shell, its helpers and curl among them.
        let processes = try #require(box.text("seen/ps"))
        let listed = processes.contains("curl")
        let leaked = processes.contains(token)
        #expect(listed, "the snapshot should list the stand-in curl")
        #expect(!leaked, "a process holds the token in its arguments")
        // The header curl is given is the one the server wants.
        #expect(box.text("seen/header") == "Authorization: Bearer \(token)\n")
    }

    /// The control: the same snapshot does catch the commands this replaces.
    @Test(arguments: [("notice", TokenInArgvFixtures.notice(title: "Claude Code"), #"{"message":"m"}"#),
                      ("agent", TokenInArgvFixtures.agent(codex: false), #"{"session_id":"s"}"#),
                      ("script", TokenInArgvFixtures.script(), "")])
    func theSnapshotSeesTheOldCommandsLeakTheToken(_ fixture: (String, String, String)) async throws {
        let token = Self.freshToken()
        let box = try Sandbox(token: token, curl: snapshotCurl)
        _ = try await box.run(fixture.1, stdin: fixture.2)
        let inArguments = try #require(box.text("seen/args")).contains(token)
        let inSnapshot = try #require(box.text("seen/ps")).contains(token)
        #expect(inArguments && inSnapshot, "\(fixture.0)")
    }

    @Test func theShippedScriptsAndCommandsNameNoTokenFileForTheShellToExpand() {
        let all = [NotifyServer.hookCommand, NotifyServer.hookCommand(title: "Gemini CLI"), NotifyServer.agentHookCommand,
                   NotifyServer.agentHookCommand(for: .codex), NotifyServer.scriptCommand, CodexNotify.script, TerminalBell.script]
        for text in all {
            #expect(!text.contains("Bearer") && !text.contains("notify-token") && !text.contains("$token"), "\(text)")
            #expect(text.contains(NotifyServer.authHeaderOption))
        }
    }

    @Test func theOpenCodePluginSendsTheTokenFromInsideOpenCodeAndStartsNoProcess() {
        let plugin = NotifyIntegration.openCodePlugin
        #expect(plugin.contains("fetch(") && plugin.contains("Authorization: `Bearer ${token}`"))
        for spawning in ["child_process", "spawn", "exec", "Bun.$", "Bun.spawn", "$`", "system("] {
            #expect(!plugin.contains(spawning), "\(spawning)")
        }
        // Its imports are the three it reads the token and the home folder with and proves a permission answer with.
        #expect(plugin.components(separatedBy: "\n").filter { $0.hasPrefix("import ") }
                == ["import { createHash, createHmac, randomBytes, timingSafeEqual } from \"node:crypto\"",
                    "import { readFileSync } from \"node:fs\"", "import { homedir } from \"node:os\""])
    }

    @Test func theHeaderFileHoldsExactlyOneHeaderLineAndIsPrivate() throws {
        try withTempHome { _ in
            let server = NotifyServer()
            let text = try String(contentsOf: NotifyServer.authHeaderURL, encoding: .utf8)
            #expect(text == "Authorization: Bearer \(server.token)\n")
            let mode = try FileManager.default.attributesOfItem(atPath: NotifyServer.authHeaderURL.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
    }

    @Test func aStaleOrLooseHeaderFileIsMadeRightAndNoTokenMeansNoFile() throws {
        try withTempHome { home in
            NotifyServer.syncAuthHeader()
            #expect(!FileManager.default.fileExists(atPath: NotifyServer.authHeaderURL.path))
            let server = NotifyServer()
            try "Authorization: Bearer stale\n".write(to: NotifyServer.authHeaderURL, atomically: true, encoding: .utf8)
            NotifyServer.syncAuthHeader()
            #expect(try String(contentsOf: NotifyServer.authHeaderURL, encoding: .utf8) == "Authorization: Bearer \(server.token)\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: NotifyServer.authHeaderURL.path)
            NotifyServer.syncAuthHeader()
            let mode = try FileManager.default.attributesOfItem(atPath: NotifyServer.authHeaderURL.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            // Nothing but the two files, no scratch file left by the replacement.
            let names = try FileManager.default.contentsOfDirectory(atPath: NotifyServer.tokenURL.deletingLastPathComponent().path)
            #expect(names.sorted() == ["notify-auth", "notify-token", "permission-key"], "\(names) in \(home.lastPathComponent)")
        }
    }
}

/// Real curl, a real server on a port of its own, and a snapshot of every process's command line taken as curl starts.
@MainActor
struct HookTokenRealRunTests {
    private final class Seen: @unchecked Sendable {
        var notices: [NotifyServer.Notice] = []
        var agents: [AgentEvent] = []
        var count: Int { notices.count + agents.count }
    }

    private func listening(token: String? = nil, seed: (URL) throws -> Void = { _ in }) async throws -> (PermissionTestServer, Seen) {
        let server = try await PermissionTestServer(token: token, seed: seed)
        let seen = Seen()
        server.server.onNotify = { seen.notices.append($0) }
        server.server.onAgent = { seen.agents.append($0) }
        let bin = server.home.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = bin.appendingPathComponent("curl")
        try StubTool.write("""
            #!/bin/sh
            ps -axww -o command= > "$HOME/ps-snapshot"
            exec /usr/bin/curl "$@"
            """, to: shim)
        return (server, seen)
    }

    private func run(_ command: String, stdin: String, in server: PermissionTestServer) async throws {
        let process = try HookProcess(command: command, home: server.home.url, stdin: Data(stdin.utf8),
                                      path: "\(server.home.url.path)/bin:/usr/bin:/bin", environment: ["__CFBundleIdentifier": "com.x"])
        let done = try #require(await process.finish())
        #expect(done.status == 0)
    }

    private func snapshot(_ server: PermissionTestServer) throws -> String {
        try String(contentsOf: server.home.url.appendingPathComponent("ps-snapshot"), encoding: .utf8)
    }

    @Test(arguments: Shape.allCases) fileprivate func theRequestAuthenticatesAndNoProcessShowedTheToken(shape: Shape) async throws {
        let (server, seen) = try await listening()
        let command = try shape.command(in: server.home.url, port: server.port)
        try await run(command, stdin: shape.stdin, in: server)
        await eventually { seen.count == 1 }
        #expect(seen.count == 1, "the server refused the request, or never got it")
        switch shape {
        case .agentClaude, .agentCodex: #expect(seen.agents.count == 1 && seen.agents.first?.session == "s-1")
        case .notice, .gemini: #expect(seen.notices.first?.message == "Needs you")
        case .codexNotify: #expect(seen.notices.first?.message == "All done")
        case .script: #expect(seen.notices.first?.message == "Done")
        case .terminalBell: #expect(seen.notices.first?.message == "work · api")
        }
        let processes = try snapshot(server)
        let listed = processes.contains("curl")
        let leaked = processes.contains(server.token)
        #expect(listed, "the snapshot should list curl")
        #expect(!leaked, "a process holds the token in its arguments")
    }

    @Test func aWrongHeaderFileIsRefusedSoItIsTheFileThatAuthenticates() async throws {
        let (server, seen) = try await listening()
        try "Authorization: Bearer \(String(repeating: "0", count: 64))\n".write(to: server.home.url.appendingPathComponent(
            "Library/Application Support/Nunsseop/notify-auth"), atomically: true, encoding: .utf8)
        try await run(NotifyServer.scriptCommand(port: server.port), stdin: "", in: server)
        try await Task.sleep(for: .milliseconds(500))
        #expect(seen.count == 0)
    }

    @Test func theTokenThatWasThereIsKeptAndEveryConsumerUsesIt() async throws {
        let old = String(repeating: "a1", count: 32)
        let (server, seen) = try await listening(token: old, seed: { home in
            // Claude Code with 0.28's hooks, which put the token on curl's command line.
            let settings = try JSONHook.adding([("Notification", TokenInArgvFixtures.notice(title: "Claude Code")),
                                                ("Stop", TokenInArgvFixtures.agent(codex: false))], to: [:])
            try NotifyIntegration.writeJSON(settings, to: home.appendingPathComponent(".claude/settings.json"))
        })
        // Nothing makes the token new: the old hooks and the new ones go on using the one that is there.
        #expect(server.token == old)
        #expect(try String(contentsOf: server.home.tokenFile, encoding: .utf8) == old)

        try await run(TokenInArgvFixtures.script(port: server.port), stdin: "", in: server)
        await eventually { seen.count == 1 }
        #expect(seen.notices.count == 1)

        try await run(NotifyServer.hookCommand(title: "Claude Code", port: server.port), stdin: #"{"message":"m"}"#, in: server)
        await eventually { seen.count == 2 }
        #expect(seen.count == 2)

        // The permission gate holds the key the hook reads, a secret of its own: a prompt is accepted, and answered in the notch.
        #expect(server.permissionKey != old && server.permissionKey.count == 64)
        #expect(try String(contentsOf: server.home.permissionKeyFile, encoding: .utf8) == server.permissionKey)
        let hook = try HookProcess(command: server.hookCommand, home: server.home.url,
                                   stdin: PermissionTestServer.hookInput(input: ["command": "echo kept-4d2f"]))
        await eventually { server.events.prompts.count == 1 }
        #expect(server.events.prompts.first?.detail == "echo kept-4d2f")
        server.server.permissions.answer(server.events.prompts[0].id, .allow)
        #expect(await hook.finish()?.stdout.isEmpty == false)
    }
}

struct TokenMigrationTests {
    private let fileManager = FileManager.default
    private let claude = NotifyIntegration.claudeCode, codex = NotifyIntegration.codex, gemini = NotifyIntegration.gemini
    private let oldToken = String(repeating: "c7", count: 32)

    private func put(_ text: String, at url: URL, mode: Int? = nil) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let mode { try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func mode(_ url: URL) -> Int? { try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }

    private func hooks(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        hooks(settings, event).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private func group(_ command: String) -> [String: Any] { ["hooks": [["type": "command", "command": command]]] }

    private let events = ["Notification", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"]

    /// Claude Code, Gemini CLI, Codex and the terminal script all as 0.28 left them, each beside another tool's hook.
    private func seedOldInstall(_ home: URL) throws {
        var claudeHooks: [String: Any] = [:]
        for event in events { claudeHooks[event] = [group("muxy-hook \(event)")] }
        claudeHooks["Notification"] = [group("muxy-hook Notification"), group(TokenInArgvFixtures.notice(title: "Claude Code"))]
        for event in events { claudeHooks[event] = (claudeHooks[event] as! [Any]) + [group(TokenInArgvFixtures.agent(codex: false))] }
        // Pasted by the user from "Copy command for scripts" into a hook of their own: not Nunsseop's to touch.
        claudeHooks["PreCompact"] = [group(TokenInArgvFixtures.script())]
        claudeHooks["PermissionRequest"] = [["hooks": [["type": "command", "command": NotifyServer.permissionHookCommand, "timeout": 600]]]]
        try NotifyIntegration.writeJSON(["model": "opus", "hooks": claudeHooks], to: claude.configURL)

        try NotifyIntegration.writeJSON(["hooks": ["Notification": [group("mine.sh"), group(TokenInArgvFixtures.notice(title: "Gemini CLI"))]]],
                                        to: gemini.configURL)

        try put(CodexNotify.adding(to: "notify = [\"/usr/bin/say\"]\nmodel = \"o3\"\n"), at: codex.configURL)
        try put(TokenInArgvFixtures.codexScript(), at: CodexNotify.scriptURL, mode: 0o755)
        var codexHooks: [String: Any] = [:]
        for event in ["UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"] {
            codexHooks[event] = [group("other-tool \(event)"), group(TokenInArgvFixtures.agent(codex: true))]
        }
        try NotifyIntegration.writeJSON(["hooks": codexHooks], to: codex.hooksURL)

        try put(NotifyIntegration.openCodePlugin, at: NotifyIntegration.openCode.configURL)
        try put(TokenInArgvFixtures.terminalScript(), at: TerminalBell.scriptURL, mode: 0o755)
    }

    @Test func everyOldFormIsReplacedBesideOtherToolsHooksAndTheTokenStays() throws {
        try withTempHome { home in
            try NotifyIntegration.$permissionPromptsOverride.withValue(true) {
                try seedOldInstall(home)
                try put(oldToken, at: NotifyServer.tokenURL, mode: 0o600)
                let plugin = text(NotifyIntegration.openCode.configURL)
                #expect(NotifyIntegration.holdsLegacyTokenCommands)

                // Launch: the server comes first and keeps the token; the old commands read the file when they run.
                let server = NotifyServer()
                #expect(server.token == oldToken)
                #expect(text(NotifyServer.tokenURL) == oldToken && mode(NotifyServer.tokenURL) == 0o600)
                #expect(text(NotifyServer.authHeaderURL) == "Authorization: Bearer \(oldToken)\n" && mode(NotifyServer.authHeaderURL) == 0o600)
                #expect(NotifyIntegration.holdsLegacyTokenCommands)

                // What the feature's start does at launch, then what updates the connected tools.
                TerminalBell.install()
                NotifyIntegration.updateConnectedNow()
                #expect(!NotifyIntegration.holdsLegacyTokenCommands)

                let settings = try NotifyIntegration.loadJSON(at: claude.configURL)
                #expect(JSONHook.isCurrent(claude.hooks, in: settings))
                #expect(settings["model"] as? String == "opus")
                for event in events { #expect(commands(settings, event).contains("muxy-hook \(event)"), "\(event)") }
                #expect(commands(settings, "PreCompact") == [TokenInArgvFixtures.script()])
                #expect(commands(settings, "PermissionRequest") == [NotifyServer.permissionHookCommand])
                #expect(!events.contains { commands(settings, $0).contains { $0.contains("Bearer") } })

                let geminiSettings = try NotifyIntegration.loadJSON(at: gemini.configURL)
                #expect(JSONHook.isCurrent(gemini.hooks, in: geminiSettings))
                #expect(commands(geminiSettings, "Notification").contains("mine.sh"))

                let codexHooks = try NotifyIntegration.loadJSON(at: codex.hooksURL)
                #expect(JSONHook.isCurrent(codex.hooks, in: codexHooks))
                for event in ["UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"] {
                    #expect(commands(codexHooks, event).contains("other-tool \(event)"), "\(event)")
                }
                #expect(text(CodexNotify.scriptURL) == CodexNotify.script && mode(CodexNotify.scriptURL) == 0o755)
                // Codex's notify line still runs the command that was there before, behind the script.
                let config = try #require(text(codex.configURL))
                #expect(CodexNotify.isInstalled(in: config) && config.contains("\"/usr/bin/say\""))
                #expect(text(NotifyIntegration.openCode.configURL) == plugin)

                #expect(text(TerminalBell.scriptURL) == TerminalBell.script)

                // The next launch keeps what it finds.
                #expect(NotifyServer().token == oldToken)
                // And running the migration again changes nothing.
                let before = [claude.configURL, gemini.configURL, codex.hooksURL, codex.configURL].map { text($0) }
                NotifyIntegration.updateConnectedNow()
                #expect([claude.configURL, gemini.configURL, codex.hooksURL, codex.configURL].map { text($0) } == before)
            }
        }
    }

    @Test func replacingLegacyCommandsWithoutTheFeatureOnDoesTheSameAndAddsNoBellScript() throws {
        try withTempHome { _ in
            try put(TokenInArgvFixtures.terminalScript(), at: TerminalBell.scriptURL, mode: 0o755)
            try put(oldToken, at: NotifyServer.tokenURL, mode: 0o600)
            try NotifyIntegration.writeJSON(JSONHook.adding([("Notification", TokenInArgvFixtures.notice(title: "Claude Code"))], to: [:]),
                                            to: claude.configURL)
            NotifyIntegration.replaceLegacyTokenCommandsNow()
            #expect(!NotifyIntegration.holdsLegacyTokenCommands)
            #expect(text(TerminalBell.scriptURL) == TerminalBell.script)
            #expect(JSONHook.isCurrent(claude.hooks, in: try NotifyIntegration.loadJSON(at: claude.configURL)))

            // With nothing old in place it touches nothing, and creates no bell script.
            try fileManager.removeItem(at: TerminalBell.scriptURL)
            let settings = text(claude.configURL)
            NotifyIntegration.replaceLegacyTokenCommandsNow()
            #expect(!fileManager.fileExists(atPath: TerminalBell.scriptURL.path) && text(claude.configURL) == settings)
        }
    }

    @Test func aPastedScriptCommandOrAStaleScriptNothingRunsIsNotTakenForAnOldHook() throws {
        try withTempHome { _ in
            try put(oldToken, at: NotifyServer.tokenURL, mode: 0o600)
            // A user's own hook under another event than Notification, which Nunsseop never touches.
            try NotifyIntegration.writeJSON(["hooks": ["Stop": [group(TokenInArgvFixtures.script())]]], to: claude.configURL)
            let settings = text(claude.configURL)
            // An old script left in Application Support by a Codex connection that is gone: no notify line runs it.
            try put(TokenInArgvFixtures.codexScript(), at: CodexNotify.scriptURL, mode: 0o755)
            try put("model = \"o3\"\n", at: codex.configURL)
            #expect(!NotifyIntegration.holdsLegacyTokenCommands)
            NotifyIntegration.replaceLegacyTokenCommandsNow()
            #expect(text(claude.configURL) == settings && text(CodexNotify.scriptURL) == TokenInArgvFixtures.codexScript())
        }
    }

    @Test func eachOldFormAloneIsFoundAndReplacedAndNeverMakesTheTokenNew() throws {
        let forms: [(String, (URL) throws -> Void)] = [
            ("claude notice", { _ in try NotifyIntegration.writeJSON(JSONHook.adding([("Notification", TokenInArgvFixtures.notice(title: "Claude Code"))], to: [:]), to: self.claude.configURL) }),
            ("claude agent only", { _ in try NotifyIntegration.writeJSON(JSONHook.adding([("Stop", TokenInArgvFixtures.agent(codex: false))], to: [:]), to: self.claude.configURL) }),
            ("gemini", { _ in try NotifyIntegration.writeJSON(JSONHook.adding([("Notification", TokenInArgvFixtures.notice(title: "Gemini CLI"))], to: [:]), to: self.gemini.configURL) }),
            ("codex hooks", { _ in try NotifyIntegration.writeJSON(JSONHook.adding([("Stop", TokenInArgvFixtures.agent(codex: true))], to: [:]), to: self.codex.hooksURL) }),
            ("codex notify script", { _ in
                try self.put(CodexNotify.adding(to: ""), at: self.codex.configURL)
                try self.put(TokenInArgvFixtures.codexScript(), at: CodexNotify.scriptURL, mode: 0o755)
            }),
            ("terminal script", { _ in try self.put(TokenInArgvFixtures.terminalScript(), at: TerminalBell.scriptURL, mode: 0o755) }),
        ]
        for (name, seed) in forms {
            try withTempHome { home in
                try put(oldToken, at: NotifyServer.tokenURL, mode: 0o600)
                try seed(home)
                #expect(NotifyIntegration.holdsLegacyTokenCommands, "\(name)")
                #expect(NotifyServer().token == oldToken, "\(name)")
                NotifyIntegration.replaceLegacyTokenCommandsNow()
                #expect(!NotifyIntegration.holdsLegacyTokenCommands, "\(name)")
                #expect(NotifyServer().token == oldToken, "\(name)")
            }
        }
    }

    @Test func aFreshInstallMakesATokenAndTheHeaderFileTogether() throws {
        try withTempHome { _ in
            let server = NotifyServer()
            #expect(server.token.count == 64)
            #expect(text(NotifyServer.authHeaderURL) == "Authorization: Bearer \(server.token)\n")
            // The header file says nothing of the permission key, which no notice hook has any use for.
            #expect(text(NotifyServer.authHeaderURL)?.contains(server.permissionKey) == false)
        }
    }

    @Test func installingAToolMakesSureTheHeaderFileIsThere() throws {
        try withTempHome { _ in
            try put(oldToken, at: NotifyServer.tokenURL, mode: 0o600)
            #expect(!fileManager.fileExists(atPath: NotifyServer.authHeaderURL.path))
            try gemini.installNow()
            #expect(text(NotifyServer.authHeaderURL) == "Authorization: Bearer \(oldToken)\n")
        }
    }
}
