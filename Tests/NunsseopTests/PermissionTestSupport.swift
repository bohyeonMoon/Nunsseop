import Foundation
@testable import Nunsseop

struct ICUUnavailable: Error {}

/// What ICU's spoof checker makes of a scalar (asked for UTF-16 here, where the card asks for UTF-8) and its compatibility form,
/// whichever is ASCII and not the scalar: the character it can be mistaken for, nil when there is none.
func asciiLookalikes() throws -> (Unicode.Scalar) -> String? {
    typealias Open = @convention(c) (UnsafeMutablePointer<Int32>) -> OpaquePointer?
    typealias Skeleton = @convention(c) (OpaquePointer?, UInt32, UnsafePointer<UInt16>?, Int32, UnsafeMutablePointer<UInt16>?, Int32,
                                         UnsafeMutablePointer<Int32>) -> Int32
    guard let library = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW), let open = dlsym(library, "uspoof_open"),
          let skeleton = dlsym(library, "uspoof_getSkeleton") else { throw ICUUnavailable() }
    var status: Int32 = 0
    guard let checker = unsafeBitCast(open, to: Open.self)(&status), status <= 0 else { throw ICUUnavailable() }
    let skeletonOf = unsafeBitCast(skeleton, to: Skeleton.self)
    return { scalar in
        guard scalar.value >= 0x80 else { return nil }
        let text = Array(String(scalar).utf16)
        var out = [UInt16](repeating: 0, count: 64), status: Int32 = 0
        let length = Int(skeletonOf(checker, 0, text, Int32(text.count), &out, 64, &status))
        if status > 0 { return "no skeleton (\(status))" }
        if length > 0, out[0..<length].allSatisfy({ $0 < 0x80 }) { return String(decoding: out[0..<length], as: UTF16.self) }
        let compatible = String(scalar).decomposedStringWithCompatibilityMapping
        return !compatible.isEmpty && compatible.unicodeScalars.allSatisfy({ $0.value < 0x80 }) ? compatible : nil
    }
}

/// Waits for `condition`, stopping as soon as it holds; the cap only matters on a slow or busy machine.
/// It runs on the caller's actor, so a condition may read what that actor owns.
func eventually(isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async {
    let deadline = Date.now.addingTimeInterval(30)
    while !condition() && Date.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// A scratch home folder holding a notify token, removed when this goes away.
final class ScratchHome {
    let url: URL
    let tokenFile: URL

    init(token: String? = nil) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-test-\(UUID().uuidString.prefix(8))")
        tokenFile = url.appendingPathComponent("Library/Application Support/Nunsseop/notify-token")
        try FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let token {
            try Data(token.utf8).write(to: tokenFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// What the server told the app about prompts.
final class PromptEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [PermissionPrompt] = []
    private var gone: [UUID] = []

    var prompts: [PermissionPrompt] { lock.withLock { shown } }
    var goneIDs: [UUID] { lock.withLock { gone } }

    func add(_ prompt: PermissionPrompt) { lock.withLock { shown.append(prompt) } }
    func remove(_ id: UUID) { lock.withLock { gone.append(id) } }
}

/// A server on a port the system picks when it listens (never 47750, where a running Nunsseop may listen), with a scratch token.
@MainActor
final class PermissionTestServer {
    let home: ScratchHome
    let server: NotifyServer
    let events: PromptEvents
    let port: UInt16

    init(hold: Double = PermissionGate.holdSeconds) async throws {
        let home = try ScratchHome()
        let server = NotifyIntegration.$homeOverride.withValue(home.url) { NotifyServer(port: 0, permissionHold: hold) }
        let events = PromptEvents()
        server.permissions.onPrompt = { events.add($0) }
        server.permissions.onGone = { events.remove($0) }
        server.start()
        var bound = server.listeningPort
        let deadline = Date.now.addingTimeInterval(30)
        while bound == nil && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            bound = server.listeningPort
        }
        guard let bound else {
            server.stop()
            throw POSIXError(.ETIMEDOUT)
        }
        self.home = home
        self.server = server
        self.events = events
        port = bound
    }

    deinit { server.stop() }

    var token: String { server.token }

    /// The hook as Claude Code runs it, aimed at this server.
    var hookCommand: String { NotifyServer.permissionHookCommand(port: port) }

    /// A request with a correct proof for `nonce`, unless told otherwise.
    func request(body: Data, nonce: String = PermissionTestServer.nonce(), proof: String? = nil, path: String = "/permission",
                 method: String = "POST") -> Data {
        let proof = proof ?? PermissionWire.requestProof(token: token, nonce: nonce, body: body)
        let head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Nonce: \(nonce)\r\nX-Proof: \(proof)\r\n"
            + "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }

    nonisolated static func nonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    nonisolated static func hookInput(tool: String = "Bash", input: [String: Any] = ["command": "npm run build"], cwd: String = "/Users/me/proj",
                          suggestions: [[String: Any]]? = nil) -> Data {
        var json: [String: Any] = ["session_id": "s-1", "cwd": cwd, "permission_mode": "default",
                                   "hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input]
        if let suggestions { json["permission_suggestions"] = suggestions }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    nonisolated(unsafe) static let addRules: [String: Any] = [
        "type": "addRules", "behavior": "allow", "destination": "localSettings",
        "rules": [["toolName": "Bash", "ruleContent": "npm run *"]],
    ]
    nonisolated(unsafe) static let setMode: [String: Any] = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
}

/// A plain loopback client, so a request can be as wrong as a test needs.
final class RawClient: @unchecked Sendable {
    private var fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: port.bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            // The failed init still runs deinit, which must not close the descriptor a second time.
            close()
            throw POSIXError(.ECONNREFUSED)
        }
    }

    deinit { close() }

    func close() {
        guard fd >= 0 else { return }
        Foundation.close(fd)
        fd = -1
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < data.count {
                let count = Foundation.send(fd, buffer.baseAddress! + sent, data.count - sent, 0)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
    }

    /// Everything the server sends until it closes the connection or `seconds` pass without a byte. The wait is off the
    /// main actor, so other tests keep running.
    func read(timeout seconds: Int = 2) async -> Data {
        let fd = fd
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var timeout = timeval(tv_sec: seconds, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var result = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = recv(fd, &buffer, buffer.count, 0)
                    if count <= 0 { break }
                    result.append(contentsOf: buffer[..<count])
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Whether the server closes the connection within `seconds`, as opposed to leaving it open and silent. Anything it says
    /// before that is discarded.
    func closes(within seconds: Int) async -> Bool {
        let fd = fd
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var timeout = timeval(tv_sec: seconds, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var buffer = [UInt8](repeating: 0, count: 4096)
                var count = recv(fd, &buffer, buffer.count, 0)
                while count > 0 { count = recv(fd, &buffer, buffer.count, 0) }
                continuation.resume(returning: count == 0)
            }
        }
    }

    /// The status line of the answer, nil when the server said nothing.
    func status(timeout seconds: Int = 2) async -> String? {
        let text = String(decoding: await read(timeout: seconds), as: UTF8.self)
        return text.isEmpty ? nil : text.components(separatedBy: "\r\n").first
    }
}

/// A shell command running, as Claude Code runs a hook: `sh -c`, the event JSON on stdin, a small environment.
final class HookProcess: @unchecked Sendable {
    let process = Process()
    private let output = Pipe()
    private var collected: Data?
    private let lock = NSLock()

    /// Nothing but /dev/null may be written to, by the shell or anything it starts.
    private static let writesNothing = "(version 1)(allow default)(deny file-write*)(allow file-write* (literal \"/dev/null\"))"

    /// - path: the folders searched for commands.
    /// - writesNothing: runs under a sandbox that refuses every file write, so a hook that needs one fails.
    init(command: String, home: URL, stdin: Data, path: String = "/usr/bin:/bin", environment: [String: String] = [:],
         writesNothing: Bool = false) throws {
        if writesNothing {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", Self.writesNothing, "/bin/sh", "-c", command]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
        }
        process.environment = ["HOME": home.path, "PATH": path].merging(environment) { $1 }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let reader = output.fileHandleForReading
        DispatchQueue.global().async { [self] in
            let data = reader.readDataToEndOfFile()
            lock.withLock { collected = data }
        }
        // A hook that ends without reading its input closes the pipe; that must not take the test process with it.
        signal(SIGPIPE, SIG_IGN)
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()
    }

    /// Waits for the command to end; nil if it is still running after the cap.
    func finish() async -> (stdout: String, status: Int32)? {
        let deadline = Date.now.addingTimeInterval(30)
        while process.isRunning && Date.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        guard !process.isRunning else { return nil }
        // A curl left behind would hold the output open; what was written by then is what counts.
        let outputDeadline = Date.now.addingTimeInterval(5)
        while lock.withLock({ collected == nil }) && Date.now < outputDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        return (lock.withLock { String(decoding: collected ?? Data(), as: UTF8.self) }, process.terminationStatus)
    }

    var isRunning: Bool { process.isRunning }

    func terminate() { process.terminate() }

    deinit { if process.isRunning { process.terminate() } }
}
