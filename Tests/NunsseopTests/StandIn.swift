import Darwin
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

/// A loopback port where no daemon is and none can come: it is taken by a listener that hangs up on every connection at once, so a client
/// that goes there finds nothing to talk to, and no other listener can be given the port. A stand-in daemon that was started and stopped is
/// not that: its port is let go of, and a stand-in of another test that runs beside this one can be answering there instead. (A port that
/// is bound and not listened on is no better: the system ignores a connection to it for eight seconds before it fails.)
final class RefusingPort: @unchecked Sendable {
    let port: UInt16
    private let stop = Stop()

    private final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isStopped: Bool { lock.withLock { stopped } }
        func set() { lock.withLock { stopped = true } }
    }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0 }
        } && listen(descriptor, 16) == 0
        guard ready else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        port = UInt16(bigEndian: address.sin_port)
        // A thread of its own: a queue of the system's can be busy for a minute with the blocking reads of other tests.
        let stop = stop
        let thread = Thread {
            while !stop.isStopped {
                var poll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&poll, 1, 100) > 0 else { continue }
                let client = accept(descriptor, nil, nil)
                if client >= 0 { close(client) }
            }
            close(descriptor)
        }
        thread.start()
    }

    deinit { stop.set() }
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
        await eventually { kill(pid, 0) != 0 }
        let ended = kill(pid, 0) != 0
        if !ended { kill(pid, SIGKILL) }
        #expect(ended)
    }

    @Test func aRefusingPortHangsUpOnEveryConnectionAndCannotBeBoundByAnother() async throws {
        let held = try RefusingPort()
        // Connected and hung up on, at once, however many times.
        for _ in 0..<3 {
            let client = try RawClient(port: held.port)
            #expect(await client.closes(within: Int(eventDeadline)))
        }
        // And the port is taken, so no listener of another test can be given it.
        let other = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(other) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: held.port.bigEndian,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let (bound, error) = withExtendedLifetime(held) {
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(other, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            return (bound, errno)
        }
        #expect(bound != 0 && error == EADDRINUSE)
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

struct HookProcessTests {
    /// What a command printed is whole once it has ended, whatever a program it started and left behind does with the output afterwards. (It
    /// used to be read by a thread to the end of a pipe, which that program held open: `finish` gave up on it after five seconds and
    /// answered with no output at all.)
    @Test func theOutputOfACommandThatHasEndedIsWholeAndAProgramLeftBehindDoesNotHoldItUp() async throws {
        let home = try ScratchHome()
        let gate = home.url.appendingPathComponent("gate").path
        // The program left behind ends when the gate is opened, when the folder holding it is gone (the test removes it as it ends, and may do so
        // before the program has looked), or when this process is: a run left one of them looping for each test, until the machine was restarted.
        let hook = try HookProcess(command: "echo first; (while [ -d '\(home.url.path)' ] && [ ! -e '\(gate)' ] && kill -0 \(getpid()) 2>/dev/null; do sleep 0.05; done; echo late) & echo second",
                                   home: home.url, stdin: Data())
        defer { FileManager.default.createFile(atPath: gate, contents: Data()) }
        let result = try #require(await hook.finish())
        #expect(result.stdout == "first\nsecond\n" && result.status == 0)
    }

    @Test func moreOutputThanAPipeHoldsIsKept() async throws {
        let home = try ScratchHome()
        let hook = try HookProcess(command: "head -c 300000 /dev/zero | tr '\\0' x", home: home.url, stdin: Data())
        let result = try #require(await hook.finish())
        #expect(result.stdout.utf8.count == 300_000 && result.status == 0)
    }
}

struct RawClientTests {
    /// A client connected to a listener of this test, and the server's end of that connection, which a test closes in the way it needs.
    private func connection() throws -> (client: RawClient, server: Int32, listener: Int32) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 }
        } && listen(listener, 1) == 0
        guard ready else {
            close(listener)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        let client = try RawClient(port: UInt16(bigEndian: address.sin_port))
        return (client, accept(listener, nil, nil), listener)
    }

    @Test func aServerThatHangsUpIsSeenToCloseTheConnection() async throws {
        let (client, server, listener) = try connection()
        defer { close(listener) }
        close(server)
        #expect(await client.closes(within: 5))
    }

    /// The system resets a connection whose end of the stream nobody has read for a minute after the server closed it, so a test whose task is
    /// resumed that late reads a reset where it would have read the end. The server has closed in both cases.
    @Test func aServerThatResetsTheConnectionIsSeenToCloseIt() async throws {
        let (client, server, listener) = try connection()
        defer { close(listener) }
        var linger = linger(l_onoff: 1, l_linger: 0)
        setsockopt(server, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
        close(server)
        #expect(await client.closes(within: 5))
    }

    @Test func aServerThatLeavesTheConnectionOpenAndSilentIsNotSeenToCloseIt() async throws {
        let (client, server, listener) = try connection()
        defer {
            close(server)
            close(listener)
        }
        #expect(await !client.closes(within: 1))
    }
}

@MainActor
struct EventuallyTests {
    /// The main actor is kept from running for longer than the cap, as other tests keep it on a loaded machine, and what the wait is for happens
    /// in a job that was queued after the wait's own timer fired: it runs right after the wait is first resumed, which is past the cap.
    @Test func aWaitThatTheActorCouldNotResumeForLongerThanTheCapStillSeesWhatComesAfterwards() async {
        var arrived = false
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 1.5) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { arrived = true }
        await eventually(within: 1.2) { arrived }
        #expect(arrived)
    }

    @Test func aWaitForWhatNeverComesEndsAtTheCap() async {
        let start = Date.now
        await eventually(within: 0.5) { false }
        #expect(Date.now.timeIntervalSince(start) >= 0.5)
    }
}
