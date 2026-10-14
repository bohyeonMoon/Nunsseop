import Foundation
import Testing

/// Stand-in servers that tests start (a herdr socket, an HTTP server) and that run until a test stops them. They must neither keep the output of the
/// test run open nor outlive it. `swift test` reads the test process's output until every holder of it has closed it, so a Python stand-in left behind
/// by a test process that crashed (a failed expectation that is followed by a subscript out of range, say) kept `swift test` waiting for good, and CI
/// ran into its job timeout instead of reporting the crash. So a stand-in has no standard output of the runner's (`/dev/null`, or a pipe of the
/// test's own), and it ends once the process that started it is gone.
enum StandIn {
    /// The start of every Python stand-in: ends the interpreter once its parent is gone (the parent of an orphan is launchd, 1), or was gone at the start.
    static let exitsWithParent = """
    import os, threading, time
    def _watch_parent(parent=os.getppid()):
        while parent != 1 and os.getppid() == parent:
            time.sleep(1)
        os._exit(0)
    threading.Thread(target=_watch_parent, daemon=True).start()

    """

    /// What Python is given to run `script` with `arguments` (`sys.argv[1...]`).
    static func pythonArguments(_ script: String, _ arguments: [String]) -> [String] {
        ["-c", exitsWithParent + script] + arguments
    }

    /// A Python process running `script` with `arguments`. `output` is the pipe the test reads from it, if it does.
    static func python(_ script: String, arguments: [String] = [], output: Pipe? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = pythonArguments(script, arguments)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}

struct StandInTests {
    /// Which files processes 0, 1 and 2 of `pid` have open, by lsof; a wait of five seconds at most.
    private func standardFiles(of pid: pid_t) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(pid)", "-d", "0,1,2", "-Fn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    @Test func aStandInHasNoneOfTheRunnersOutput() throws {
        let process = try StandIn.python("import time; time.sleep(60)")
        defer { process.terminate() }
        #expect(try standardFiles(of: process.processIdentifier) == ["/dev/null", "/dev/null", "/dev/null"])
    }

    /// A test process that crashes runs none of its cleanup, and its orphans live on, unless they end on their own. Here the stand-in's parent is a shell
    /// that ends at once; the stand-in must follow within seconds (it checks once a second). It is waited for 20 seconds, and killed after that.
    @Test func aStandInEndsOnceItsParentIsGone() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", #"/usr/bin/python3 "$@" >/dev/null 2>&1 </dev/null & echo $!; sleep 2"#, "sh"] + StandIn.pythonArguments("import time; time.sleep(300)", [])
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        let line = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        shell.waitUntilExit()
        let pid = try #require(pid_t(line))
        let deadline = Date.now.addingTimeInterval(eventDeadline)
        while kill(pid, 0) == 0 && Date.now < deadline { try await Task.sleep(for: .milliseconds(200)) }
        let ended = kill(pid, 0) != 0
        if !ended { kill(pid, SIGKILL) }
        #expect(ended)
    }

    /// Every Python a test starts is started by `StandIn.python`, so none of them can keep the output of the run open.
    @Test func everyPythonStandInIsStartedByTheHelper() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var users: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("\"/usr/bin/python3\"") && file.lastPathComponent != "StandIn.swift" { users.append(file.lastPathComponent) }
        }
        #expect(users.isEmpty, "start Python with StandIn.python: \(users)")
    }
}
