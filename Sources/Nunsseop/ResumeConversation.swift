import AppKit
import Foundation

/// The terminal a conversation is resumed in. Muxy is left out: it can't open a visible tab from outside.
enum ResumeTerminal: String, CaseIterable, Identifiable {
    case ghostty, cmux, terminal

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ghostty: "Ghostty"
        case .cmux: "cmux"
        case .terminal: "Terminal"
        }
    }

    var bundleID: String {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"
        case .cmux: Cmux.bundleID
        case .terminal: "com.apple.Terminal"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Terminal is always there.
    static var installed: [ResumeTerminal] { allCases.filter { $0 == .terminal || $0.appURL != nil } }

    /// The saved choice when it is installed, else Ghostty when it is, else Terminal.
    static func effective(saved: String, installed: [ResumeTerminal]) -> ResumeTerminal {
        if let chosen = ResumeTerminal(rawValue: saved), installed.contains(chosen) { return chosen }
        return installed.contains(.ghostty) ? .ghostty : .terminal
    }
}

/// Opens a conversation again with `claude --resume` or `codex resume` in a new terminal window in its folder.
/// Programs started by an app don't get the shell's PATH, so the command runs through the user's login shell.
enum Resume {
    /// What the terminals are run with, so a test can run none.
    struct Launcher {
        /// Runs a program to its end; nil when it failed.
        var run: (URL, [String]) -> String?
        var sleep: (TimeInterval) -> Void

        static let live = Launcher(run: { TerminalFocus.run($0, $1, environment: Resume.environment(ProcessInfo.processInfo.environment)) },
                                   sleep: { Thread.sleep(forTimeInterval: $0) })
    }

    /// Where the terminals are and what is needed to start them.
    struct Setup {
        var installed: [ResumeTerminal]
        var ghostty: URL?
        var cmuxCLI: URL?
        /// Whether cmux is running already, in which case a socket that doesn't answer is a refusal, not a start-up.
        var cmuxRunning = false
        /// The user's login shell.
        var shell: String
        /// A private folder for the script Terminal opens is made in here.
        var scripts: URL

        static var live: Setup {
            Setup(installed: ResumeTerminal.installed, ghostty: ResumeTerminal.ghostty.appURL, cmuxCLI: Cmux.cli,
                  cmuxRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: Cmux.bundleID).isEmpty,
                  shell: Resume.shell(from: ProcessInfo.processInfo.environment["SHELL"]),
                  scripts: FileManager.default.temporaryDirectory)
        }
    }

    static let openTool = URL(fileURLWithPath: "/usr/bin/open")

    /// How long cmux gets to answer after being started.
    private static let cmuxAttempts = 20
    private static let cmuxPause: TimeInterval = 0.5

    /// Opens it in the terminal chosen in Settings, off the main thread. Called on the main thread.
    static let inChosenTerminal: (RecentConversation) -> Void = { conversation in
        let terminal = MainActor.assumeIsolated {
            ResumeTerminal.effective(saved: AppSettings.shared.resumeTerminal, installed: ResumeTerminal.installed)
        }
        DispatchQueue.global(qos: .userInitiated).async { open(conversation, in: terminal) }
    }

    // MARK: Safe pieces

    /// Session ids are hex digits and dashes (UUIDs, Codex's too), 8 to 64 of them.
    static func isSafeSession(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "-") }
    }

    /// An absolute path without control or line-breaking characters.
    static func isSafeFolder(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 1_024 && !path.unicodeScalars.contains {
            [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
    }

    /// What a terminal is opened with: only what a login shell doesn't set up itself, so nothing of Nunsseop's own
    /// environment reaches the conversation (a marker of the tool session Nunsseop was started from turns off
    /// Claude Code's transcripts, say).
    static func environment(_ inherited: [String: String]) -> [String: String] {
        var kept = inherited.filter { key, _ in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"].contains(key) || key.hasPrefix("LC_") }
        kept["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return kept
    }

    /// Between single quotes, which let nothing through but another single quote.
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The user's shell, when it is a plain absolute path of an executable; else zsh.
    static func shell(from environment: String?) -> String {
        guard let path = environment, path.hasPrefix("/"), path.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 && $0 != "'" }),
              FileManager.default.isExecutableFile(atPath: path) else { return "/bin/zsh" }
        return path
    }

    /// `cd -- '<folder>' && exec claude --resume '<id>'`; nil when the folder or the id could be anything but what they should be.
    static func line(_ conversation: RecentConversation) -> String? {
        guard isSafeSession(conversation.session), isSafeFolder(conversation.cwd) else { return nil }
        let command = conversation.kind == .claude ? "claude --resume" : "codex resume"
        return "cd -- \(quote(conversation.cwd)) && exec \(command) \(quote(conversation.session))"
    }

    // MARK: Terminals

    /// Opens the conversation in `terminal`, or in Terminal when that one isn't installed or can't be started.
    /// Returns the terminal that took it, nil when none did.
    @discardableResult
    static func open(_ conversation: RecentConversation, in terminal: ResumeTerminal, setup: Setup = .live, launcher: Launcher = .live) -> ResumeTerminal? {
        var isDirectory: ObjCBool = false
        guard let line = line(conversation),
              FileManager.default.fileExists(atPath: conversation.cwd, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        var order = [terminal]
        if terminal != .terminal { order.append(.terminal) }
        for candidate in order where candidate == .terminal || setup.installed.contains(candidate) {
            let opened: Bool
            switch candidate {
            case .ghostty: opened = openInGhostty(conversation.cwd, line, setup: setup, launcher: launcher)
            case .cmux: opened = openInCmux(conversation.cwd, line, setup: setup, launcher: launcher)
            case .terminal: opened = openInTerminal(line, setup: setup, launcher: launcher)
            }
            if opened { return candidate }
        }
        return nil
    }

    /// A new window of a new Ghostty process, in the folder: argv, not a shell string. The new process doesn't bring
    /// back the windows Ghostty saved, which would open beside it as tabs.
    static func ghosttyArguments(app: URL, cwd: String, line: String, shell: String) -> [String] {
        ["-na", app.path, "--args", "--window-save-state=never", "--working-directory=\(cwd)", "-e", shell, "-lc", line]
    }

    static func cmuxArguments(cwd: String, line: String) -> [String] {
        ["new-workspace", "--cwd", cwd, "--command", line, "--focus", "true"]
    }

    /// The script Terminal opens: it removes itself, then hands the line to the login shell as one `-lc` argument. It is
    /// sh whatever the user's shell is, which needn't understand any of this (fish and nu don't).
    static func terminalScript(line: String, shell: String) -> String {
        "#!/bin/sh\nrm -f -- \"$0\"\nrmdir -- \"$(dirname -- \"$0\")\" 2>/dev/null\nexec \(quote(shell)) -lc \(quote(line))\n"
    }

    private static func openInGhostty(_ cwd: String, _ line: String, setup: Setup, launcher: Launcher) -> Bool {
        guard let app = setup.ghostty else { return false }
        return launcher.run(openTool, ghosttyArguments(app: app, cwd: cwd, line: line, shell: setup.shell)) != nil
    }

    /// cmux must be running with its socket up; it is started if not, and given a few seconds. A running one that
    /// doesn't answer refuses outside processes, so it is neither brought forward nor waited for.
    private static func openInCmux(_ cwd: String, _ line: String, setup: Setup, launcher: Launcher) -> Bool {
        guard let cli = setup.cmuxCLI else { return false }
        if launcher.run(cli, ["ping"]) == nil {
            guard !setup.cmuxRunning, launcher.run(openTool, ["-b", Cmux.bundleID]) != nil else { return false }
            var answered = false
            for _ in 0..<cmuxAttempts where !answered {
                launcher.sleep(cmuxPause)
                answered = launcher.run(cli, ["ping"]) != nil
            }
            guard answered else { return false }
        }
        return launcher.run(cli, cmuxArguments(cwd: cwd, line: line)) != nil
    }

    private static func openInTerminal(_ line: String, setup: Setup, launcher: Launcher) -> Bool {
        let files = FileManager.default
        let folder = setup.scripts.appendingPathComponent("nunsseop-resume-\(UUID().uuidString)", isDirectory: true)
        let script = folder.appendingPathComponent("resume.command")
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard files.createFile(atPath: script.path, contents: Data(terminalScript(line: line, shell: setup.shell).utf8),
                                   attributes: [.posixPermissions: 0o700]) else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? files.removeItem(at: folder)
            return false
        }
        if launcher.run(openTool, ["-b", ResumeTerminal.terminal.bundleID, script.path]) != nil { return true }
        try? files.removeItem(at: folder)
        return false
    }
}
