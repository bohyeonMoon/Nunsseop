import Foundation
import Testing
@testable import Nunsseop

private let session = "5f0c2d1e-0000-4000-8000-000000000001"

/// Runs no terminal: every program is recorded, and answers as `answers` says.
private final class Recorder {
    var calls: [(program: String, arguments: [String])] = []
    var sleeps = 0
    /// Whether a program of this name (its last path component) succeeds, by how many times it has been called.
    var answers: (String, Int) -> Bool = { _, _ in true }

    var launcher: Resume.Launcher {
        Resume.Launcher(
            run: { url, arguments in
                let name = url.lastPathComponent
                let count = self.calls.filter { $0.program == name && $0.arguments.first == arguments.first }.count
                self.calls.append((name, arguments))
                return self.answers(name + ":" + (arguments.first ?? ""), count) ? "" : nil
            },
            sleep: { _ in self.sleeps += 1 })
    }
}

private func folder(_ name: String) throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-resume-\(UUID().uuidString.prefix(8))/\(name)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func conversation(_ kind: AgentKind = .claude, id: String = session, cwd: String) -> RecentConversation {
    RecentConversation(kind: kind, session: id, cwd: cwd, modified: .now)
}

private func setup(installed: [ResumeTerminal] = ResumeTerminal.allCases, scripts: URL? = nil) -> Resume.Setup {
    Resume.Setup(installed: installed, ghostty: URL(fileURLWithPath: "/Applications/Ghostty.app"),
                 cmuxCLI: URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux"), shell: "/bin/zsh",
                 scripts: scripts ?? FileManager.default.temporaryDirectory)
}

struct ResumeLineTests {
    @Test func sessionIdsAreHexDigitsAndDashes() {
        for good in [session, "01a130c4-3953-7f71-bc99-b8a6d37a5338", "ABCDEF12", String(repeating: "a", count: 64)] {
            #expect(Resume.isSafeSession(good), "\(good)")
        }
        for bad in ["", "abc", "1234567", String(repeating: "a", count: 65), "5f0c2d1e-0000'; touch x; '", "5f0c2d1e 0000", "5f0c2d1e\n0000",
                    "5f0c2d1e$(id)", "../../etc/passwd", "gggggggg-0000", "５f0c2d1e-0000"] {
            #expect(!Resume.isSafeSession(bad), "\(bad)")
        }
    }

    @Test func quotingKeepsEverythingButTheQuote() {
        #expect(Resume.quote("a b") == "'a b'")
        #expect(Resume.quote("it's") == "'it'\\''s'")
        #expect(Resume.quote("$HOME `x` \"y\" \\") == "'$HOME `x` \"y\" \\'")
        #expect(Resume.quote("") == "''")
    }

    @Test func foldersAreAbsoluteWithoutControlCharacters() {
        #expect(Resume.isSafeFolder("/Users/me/my project") && Resume.isSafeFolder("/a/it's $x `y` \"z\""))
        for bad in ["", "relative", "~/x", "/a\nb", "/a\rb", "/a\u{0}b", "/a\u{1b}[31mb", "/a\tb", "/a\u{2028}b", "/a\u{2029}b", "/a\u{7f}"] {
            #expect(!Resume.isSafeFolder(bad), "\(bad.debugDescription)")
        }
    }

    @Test func theLineChangesFolderAndReplacesTheShell() throws {
        let cwd = "/Users/me/it's here"
        #expect(Resume.line(conversation(cwd: cwd)) == "cd -- '/Users/me/it'\\''s here' && exec claude --resume '\(session)'")
        #expect(Resume.line(conversation(.codex, cwd: "/a")) == "cd -- '/a' && exec codex resume '\(session)'")
        #expect(Resume.line(conversation(id: "bad;id", cwd: "/a")) == nil)
        #expect(Resume.line(conversation(cwd: "/a\nrm -rf ~")) == nil)
        #expect(Resume.line(conversation(cwd: "relative")) == nil)
    }

    /// The line is run by a real shell with a stand-in for the tool: the arguments and the folder it gets are the ones given.
    @Test(arguments: [
        "plain", "with space", "it's", "quo\"te", "$HOME", "`echo hacked`", "a;b", "$(echo hacked)", "back\\slash", "-dash",
        "star*", "bang!", "'; touch hacked; '",
    ]) func hostileFoldersReachTheToolAsTheyAre(name: String) throws {
        let cwd = try folder(name)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: cwd).deletingLastPathComponent()) }
        let bin = URL(fileURLWithPath: cwd).deletingLastPathComponent().appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = bin.appendingPathComponent("record")
        for tool in ["claude", "codex"] {
            let script = bin.appendingPathComponent(tool)
            try "#!/bin/sh\nprintf '%s\\n' \"$(pwd)\" \"$@\" > \(Resume.quote(record.path))\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        for (kind, arguments) in [(AgentKind.claude, ["--resume", session]), (.codex, ["resume", session])] {
            try? FileManager.default.removeItem(at: record)
            let line = try #require(Resume.line(conversation(kind, cwd: cwd)))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", line]
            process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let lines = (try String(contentsOf: record, encoding: .utf8)).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            #expect(lines == [cwd] + arguments)
            #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent("hacked").path))
        }
    }

    @Test func theShellIsTheUsersWhenItIsAPlainExecutablePath() {
        #expect(Resume.shell(from: "/bin/zsh") == "/bin/zsh")
        #expect(Resume.shell(from: "/bin/bash") == "/bin/bash")
        for other in [nil, "", "zsh", "/no/such/shell", "/bin/zsh; rm -rf ~", "/bin/zs h", "/bin/zsh'", "/bin/zsh\n"] {
            #expect(Resume.shell(from: other) == "/bin/zsh", "\(other.debugDescription)")
        }
    }
}

struct ResumeTerminalChoiceTests {
    @Test func theSavedOneIfInstalledElseGhosttyElseTerminal() {
        let all = ResumeTerminal.allCases
        #expect(ResumeTerminal.effective(saved: "", installed: all) == .ghostty)
        #expect(ResumeTerminal.effective(saved: "cmux", installed: all) == .cmux)
        #expect(ResumeTerminal.effective(saved: "terminal", installed: all) == .terminal)
        #expect(ResumeTerminal.effective(saved: "cmux", installed: [.ghostty, .terminal]) == .ghostty)
        #expect(ResumeTerminal.effective(saved: "", installed: [.cmux, .terminal]) == .terminal)
        #expect(ResumeTerminal.effective(saved: "ghostty", installed: [.terminal]) == .terminal)
        #expect(ResumeTerminal.effective(saved: "muxy", installed: all) == .ghostty)
        #expect(ResumeTerminal.installed.contains(.terminal))
        #expect(ResumeTerminal.allCases.map(\.name) == ["Ghostty", "iTerm2", "WezTerm", "kitty", "cmux", "Terminal"])
        #expect(ResumeTerminal.effective(saved: "iterm", installed: all) == .iterm)
        #expect(ResumeTerminal.effective(saved: "kitty", installed: [.ghostty, .terminal]) == .ghostty)
    }
}

struct ResumeOpenTests {
    @Test func ghosttyGetsANewWindowInTheFolderAsArguments() throws {
        let cwd = try folder("it's a project")
        let recorder = Recorder()
        let used = Resume.open(conversation(cwd: cwd), in: .ghostty, setup: setup(), launcher: recorder.launcher)
        #expect(used == .ghostty)
        #expect(recorder.calls.count == 1)
        let call = try #require(recorder.calls.first)
        let line = "cd -- \(Resume.quote(cwd)) && exec claude --resume '\(session)'"
        #expect(call.program == "open")
        #expect(call.arguments == ["-na", "/Applications/Ghostty.app", "--args", "--window-save-state=never", "--working-directory=\(cwd)", "-e", "/bin/zsh", "-lc", line])
    }

    @Test func cmuxTypesTheLineIntoANewWorkspaceOfARunningApp() throws {
        let cwd = try folder("api")
        let recorder = Recorder()
        #expect(Resume.open(conversation(.codex, cwd: cwd), in: .cmux, setup: setup(), launcher: recorder.launcher) == .cmux)
        #expect(recorder.calls.map(\.program) == ["cmux", "cmux"])
        #expect(recorder.calls[0].arguments == ["ping"])
        #expect(recorder.calls[1].arguments == ["new-workspace", "--cwd", cwd, "--command", "cd -- '\(cwd)' && exec codex resume '\(session)'",
                                                "--focus", "true"])
        #expect(recorder.sleeps == 0)
    }

    @Test func cmuxIsStartedAndWaitedForWhenItDoesNotAnswer() throws {
        let cwd = try folder("api")
        let recorder = Recorder()
        recorder.answers = { name, count in name == "cmux:ping" ? count >= 3 : true }
        #expect(Resume.open(conversation(cwd: cwd), in: .cmux, setup: setup(), launcher: recorder.launcher) == .cmux)
        #expect(recorder.calls.map { $0.program + " " + ($0.arguments.first ?? "") }
                == ["cmux ping", "open -b", "cmux ping", "cmux ping", "cmux ping", "cmux new-workspace"])
        #expect(recorder.calls[1].arguments == ["-b", "com.cmuxterm.app"])
        #expect(recorder.sleeps == 3)
    }

    @Test func aRunningCmuxThatRefusesTheSocketIsNeitherBroughtForwardNorWaitedFor() throws {
        let cwd = try folder("api")
        let recorder = Recorder()
        recorder.answers = { name, _ in name != "cmux:ping" }
        var running = setup(scripts: URL(fileURLWithPath: try folder("scripts")))
        running.cmuxRunning = true
        #expect(Resume.open(conversation(cwd: cwd), in: .cmux, setup: running, launcher: recorder.launcher) == .terminal)
        #expect(recorder.calls.map { $0.program + " " + ($0.arguments.first ?? "") } == ["cmux ping", "open -b"])
        #expect(recorder.calls[1].arguments.dropLast() == ["-b", "com.apple.Terminal"])
        #expect(recorder.sleeps == 0)
        // One that answers is used as before.
        let answering = Recorder()
        #expect(Resume.open(conversation(cwd: cwd), in: .cmux, setup: running, launcher: answering.launcher) == .cmux)
        #expect(answering.calls.map { $0.arguments.first } == ["ping", "new-workspace"])
    }

    @Test func cmuxThatNeverAnswersFallsBackToTerminal() throws {
        let cwd = try folder("api")
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        let recorder = Recorder()
        recorder.answers = { name, _ in name != "cmux:ping" }
        #expect(Resume.open(conversation(cwd: cwd), in: .cmux, setup: setup(scripts: scripts), launcher: recorder.launcher) == .terminal)
        #expect(recorder.calls.filter { $0.program == "cmux" && $0.arguments == ["ping"] }.count == 21)
        #expect(recorder.sleeps == 20)
        #expect(!recorder.calls.contains { $0.arguments.first == "new-workspace" })
        #expect(recorder.calls.last?.program == "open" && recorder.calls.last?.arguments.dropLast() == ["-b", "com.apple.Terminal"])
    }

    @Test func aWorkspaceThatCannotBeMadeFallsBackToTerminal() throws {
        let cwd = try folder("api")
        let recorder = Recorder()
        recorder.answers = { name, _ in name != "cmux:new-workspace" }
        #expect(Resume.open(conversation(cwd: cwd), in: .cmux, setup: setup(scripts: URL(fileURLWithPath: try folder("scripts"))), launcher: recorder.launcher) == .terminal)
    }

    @Test func aMissingAppFallsBackToTerminal() throws {
        let cwd = try folder("api")
        for chosen in [ResumeTerminal.ghostty, .cmux] {
            let recorder = Recorder()
            let scripts = URL(fileURLWithPath: try folder("scripts"))
            #expect(Resume.open(conversation(cwd: cwd), in: chosen, setup: setup(installed: [.terminal], scripts: scripts), launcher: recorder.launcher) == .terminal)
            #expect(recorder.calls.count == 1 && recorder.calls[0].arguments.first == "-b")
        }
        // Installed but without a location to start it from.
        var noGhostty = setup(scripts: URL(fileURLWithPath: try folder("scripts")))
        noGhostty.ghostty = nil
        let recorder = Recorder()
        #expect(Resume.open(conversation(cwd: cwd), in: .ghostty, setup: noGhostty, launcher: recorder.launcher) == .terminal)
        // A Ghostty that fails to start.
        let failing = Recorder()
        failing.answers = { name, _ in name != "open:-na" }
        #expect(Resume.open(conversation(cwd: cwd), in: .ghostty, setup: setup(scripts: URL(fileURLWithPath: try folder("scripts"))), launcher: failing.launcher) == .terminal)
        #expect(failing.calls.map { $0.arguments.first } == ["-na", "-b"])
    }

    @Test func terminalOpensAPrivateScriptThatRemovesItself() throws {
        let cwd = try folder("it's \"here\" $x")
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        // A stand-in for the login shell, which records what it is given and runs the line the way `-c` does.
        let shellArguments = scripts.appendingPathComponent("shell-arguments")
        let shell = scripts.appendingPathComponent("login shell")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(Resume.quote(shellArguments.path))\nexec /bin/sh -c \"$2\"\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        var setup = setup(scripts: scripts)
        setup.shell = shell.path
        let recorder = Recorder()
        #expect(Resume.open(conversation(cwd: cwd), in: .terminal, setup: setup, launcher: recorder.launcher) == .terminal)
        let call = try #require(recorder.calls.first)
        #expect(call.program == "open" && Array(call.arguments.prefix(2)) == ["-b", "com.apple.Terminal"])
        let path = try #require(call.arguments.last)
        let attributes = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? nil }
        #expect(attributes(path) == 0o700)
        #expect(attributes(URL(fileURLWithPath: path).deletingLastPathComponent().path) == 0o700)
        #expect(path.hasPrefix(scripts.path) && path.hasSuffix(".command"))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let line = "cd -- \(Resume.quote(cwd)) && exec claude --resume '\(session)'"
        #expect(text == Resume.terminalScript(line: line, shell: shell.path))
        #expect(text.hasPrefix("#!/bin/sh\n"))

        // Run, it removes itself and its folder, and starts the tool in the folder.
        let bin = scripts.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = scripts.appendingPathComponent("record")
        let tool = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s\\n' \"$(pwd)\" \"$@\" > \(Resume.quote(record.path))\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path]
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [cwd, "--resume", session])
        // The login shell gets nothing but `-lc` and the line, so it needn't understand sh.
        #expect(try String(contentsOf: shellArguments, encoding: .utf8) == "-lc\n\(line)\n")
    }

    @Test func theScriptNeverPutsTheShellWhereItIsParsedAsCode() {
        let script = Resume.terminalScript(line: "cd -- '/a' && exec claude --resume 'abcdef12'", shell: "/opt/homebrew/bin/fish")
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.components(separatedBy: "fish").count == 2)
        #expect(script.hasSuffix(#"exec '/opt/homebrew/bin/fish' -lc 'cd -- '\''/a'\'' && exec claude --resume '\''abcdef12'\'''"# + "\n"))
    }

    @Test func aTerminalThatFailsLeavesNoScriptBehind() throws {
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        let recorder = Recorder()
        recorder.answers = { _, _ in false }
        #expect(Resume.open(conversation(cwd: try folder("api")), in: .terminal, setup: setup(scripts: scripts), launcher: recorder.launcher) == nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: scripts.path)).isEmpty)
    }

    @Test func badIdsAndFoldersStartNothing() throws {
        let cwd = try folder("api")
        let recorder = Recorder()
        let open = { (c: RecentConversation) in Resume.open(c, in: .ghostty, setup: setup(), launcher: recorder.launcher) }
        #expect(open(conversation(id: "x; rm -rf ~", cwd: cwd)) == nil)
        #expect(open(conversation(id: "../../x", cwd: cwd)) == nil)
        #expect(open(conversation(cwd: cwd + "\nrm -rf ~")) == nil)
        #expect(open(conversation(cwd: "relative")) == nil)
        // A folder that is gone, and a file.
        #expect(open(conversation(cwd: cwd + "/gone")) == nil)
        let file = cwd + "/file"
        try Data().write(to: URL(fileURLWithPath: file))
        #expect(open(conversation(cwd: file)) == nil)
        #expect(recorder.calls.isEmpty)
    }
}

struct ResumeEnvironmentTests {
    @Test func aTerminalGetsOnlyWhatALoginShellDoesntSetItself() {
        let inherited = ["HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "SHELL": "/bin/zsh", "TMPDIR": "/var/folders/x/",
                         "LANG": "ko_KR.UTF-8", "LC_CTYPE": "UTF-8", "PATH": "/opt/odd/bin", "CLAUDE_CODE_CHILD_SESSION": "1",
                         "CLAUDECODE": "1", "CODEX_COMPANION_SESSION_ID": "abc", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]
        #expect(Resume.environment(inherited) == ["HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "SHELL": "/bin/zsh",
                                                 "TMPDIR": "/var/folders/x/", "LANG": "ko_KR.UTF-8", "LC_CTYPE": "UTF-8",
                                                 "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    @Test func theCommandRunsWithThatEnvironment() throws {
        let output = try #require(TerminalFocus.run(URL(fileURLWithPath: "/usr/bin/env"), [], environment: ["A": "1"]))
        #expect(output == "A=1\n")
    }
}
