import AppKit
import CoreText
import Foundation
import Testing
@testable import Nunsseop

struct ICUUnavailable: Error {}

extension Tag {
    /// A sweep of all of Unicode, or of thousands of glyphs: seconds of CPU on every core, which starves the tests that wait for a real event
    /// with a deadline. `scripts/test.sh` and CI run these in a pass of their own, after the rest. `swift test` can't select by tag, so a test with
    /// this tag also has `exhaustive` at the start of its name (`--filter /exhaustive`), which `ExhaustiveTagTests` keeps true.
    @Tag static var exhaustive: Self
}

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

/// Whether a scalar can be read as a printable ASCII character: ICU's skeleton of it, or its NFKC or NFKD form, holds one (not the space),
/// or it is one of the strokes, dashes and full stops that the checker misses and that the card takes for ASCII (`-` `|` `.`).
func asciiMappable() throws -> (Unicode.Scalar) -> Bool {
    typealias Open = @convention(c) (UnsafeMutablePointer<Int32>) -> OpaquePointer?
    typealias Skeleton = @convention(c) (OpaquePointer?, UInt32, UnsafePointer<UInt16>?, Int32, UnsafeMutablePointer<UInt16>?, Int32,
                                         UnsafeMutablePointer<Int32>) -> Int32
    guard let library = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW), let open = dlsym(library, "uspoof_open"),
          let skeleton = dlsym(library, "uspoof_getSkeleton") else { throw ICUUnavailable() }
    var status: Int32 = 0
    guard let checker = unsafeBitCast(open, to: Open.self)(&status), status <= 0 else { throw ICUUnavailable() }
    let skeletonOf = unsafeBitCast(skeleton, to: Skeleton.self)
    let missed: Set<UInt32> = [0x3161, 0x4E00, 0x30FC, 0xFF70, 0x2014, 0x2015, 0x3163, 0x4E28, 0x3021, 0x2758, 0x3002, 0xFF61]
    func printable(_ text: String) -> Bool { text.unicodeScalars.contains { (0x21...0x7E).contains($0.value) } }
    return { scalar in
        guard scalar.value >= 0x80 else { return false }
        if missed.contains(scalar.value) { return true }
        let text = Array(String(scalar).utf16)
        var out = [UInt16](repeating: 0, count: 64), status: Int32 = 0
        let length = Int(skeletonOf(checker, 0, text, Int32(text.count), &out, 64, &status))
        if status <= 0, printable(String(decoding: out[0..<length], as: UTF16.self)) { return true }
        return printable(String(scalar).decomposedStringWithCompatibilityMapping) || printable(String(scalar).precomposedStringWithCompatibilityMapping)
    }
}

/// ICU's script of a scalar (`uscript_getScript`), by its name: "Latin", "Greek", "Cyrillic", "Common", "Inherited", and "Other" for the rest.
func scriptNames() throws -> (Unicode.Scalar) -> String {
    typealias Script = @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> Int32
    guard let library = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW), let symbol = dlsym(library, "uscript_getScript") else { throw ICUUnavailable() }
    let script = unsafeBitCast(symbol, to: Script.self)
    return { scalar in
        var status: Int32 = 0
        switch script(Int32(scalar.value), &status) {
        case 25: return "Latin"
        case 14: return "Greek"
        case 8: return "Cyrillic"
        case 0: return "Common"
        case 1: return "Inherited"
        default: return "Other"
        }
    }
}

private final class Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Runs a CPU-bound `work` on a thread of its own and waits for it without holding a thread of Swift's cooperative pool. The pool has as many
/// threads as the machine has cores (three on a CI runner), so a test that sweeps all of Unicode in its own body holds one of them for as long as
/// it takes, and with three such tests every other test that sleeps or awaits resumes only when one lets go, a minute late. `work` reports what it
/// finds in its result and leaves the expectations to the test, which makes them on its own task: an expectation made on a thread of this kind has no test to belong to.
func offPool<T: Sendable>(_ work: @escaping () -> T) async -> T {
    let job = Unchecked(work)
    return await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: job.value()) }
        // A sweep is not what anyone is waiting for at a keystroke: the tests that sleep for a few hundred milliseconds go first.
        thread.qualityOfService = .utility
        thread.stackSize = 16 << 20
        thread.start()
    }
}

/// The scalars `PermissionText.escape` leaves alone when each stands by itself. Finding them takes a pass over all of Unicode (a few seconds each), and
/// several tests build on them: it is made once for the whole run, on a thread of its own, and the tests that need it wait for it without holding a thread.
enum ShownScalars {
    /// Past ASCII, as the card shows it in a detail (a line break stays one): what the chip and run tests sweep.
    static func pastASCII() async -> [Unicode.Scalar] { await pastASCIITask.value }

    /// Of every scalar, as the card shows it in a title (a line break is written out): what the allowlist test draws.
    static func alone() async -> [Unicode.Scalar] { await aloneTask.value }

    private static let pastASCIITask = Task { () -> [Unicode.Scalar] in
        await offPool {
            (UInt32(0x80)...0x10FFFF).compactMap { value -> Unicode.Scalar? in
                guard let scalar = Unicode.Scalar(value), PermissionText.escape(String(scalar), multiline: true) == String(scalar) else { return nil }
                return scalar
            }
        }
    }

    private static let aloneTask = Task { () -> [Unicode.Scalar] in
        await offPool {
            (UInt32(0)...0x10FFFF).compactMap { Unicode.Scalar($0) }.filter {
                let text = String($0)
                return text.unicodeScalars.elementsEqual(PermissionText.escape(text, multiline: false).unicodeScalars)
            }
        }
    }
}

/// How long a test waits for a real event (a prompt that reaches the main actor, a process answering) before it gives up. A wait stops as
/// soon as its event comes, so the cap only matters when it doesn't. The main actor carries every test that draws or lays out a view, and on a
/// busy machine that queue takes most of a minute (about 50 seconds beside 40 busy processes on 11 cores), longer than the 30 seconds this
/// used to be, which failed the tests that wait behind it.
let eventDeadline: TimeInterval = 120

/// Waits for `condition`, stopping as soon as it holds; the cap only matters on a slow or busy machine.
/// It runs on the caller's actor, so a condition may read what that actor owns.
func eventually(isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async {
    let deadline = Date.now.addingTimeInterval(eventDeadline)
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
        let deadline = Date.now.addingTimeInterval(eventDeadline)
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
    private var started: Date?
    private var ended: Date?
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
        // The end is stamped by the process's own exit, on a dispatch thread, so it doesn't wait for the test's task to be resumed: on a
        // loaded runner the cooperative pool is held by long synchronous tests, and a task resumes a minute late.
        process.terminationHandler = { [self] _ in lock.withLock { ended = Date.now } }
        lock.withLock { started = Date.now }
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
        let deadline = Date.now.addingTimeInterval(eventDeadline)
        while process.isRunning && Date.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        guard !process.isRunning else { return nil }
        // A curl left behind would hold the output open; what was written by then is what counts.
        let outputDeadline = Date.now.addingTimeInterval(5)
        while lock.withLock({ collected == nil }) && Date.now < outputDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        return (lock.withLock { String(decoding: collected ?? Data(), as: UTF8.self) }, process.terminationStatus)
    }

    var isRunning: Bool { process.isRunning }

    /// How long the command ran, from its start to its exit, as the system saw them; nil while it is running.
    var lifetime: TimeInterval? { lock.withLock { ended.flatMap { end in started.map { end.timeIntervalSince($0) } } } }

    func terminate() { process.terminate() }

    deinit { if process.isRunning { process.terminate() } }
}

/// What CoreText draws `text` as in the card's code font: the font and glyph of each one that takes room. A selector may leave a
/// glyph of no width behind, which is not a drawing.
func codeDrawing(_ text: String) -> [String] {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: PermissionLayout.codeFont]))
    var drawn: [String] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
        let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count), advances = [CGSize](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
        for (glyph, advance) in zip(glyphs, advances) where advance.width > 0 { drawn.append("\(CTFontCopyPostScriptName(font)):\(glyph)") }
    }
    return drawn
}

/// Whether a selector or skin tone in `text` follows a picture that CoreText draws the same with and without it, or one that is in
/// colour already: the ones `escape` writes out wherever they stand. A colour selector that makes no difference after a picture that is not
/// in colour is not among them, because a sequence drawn as one keeps it.
func hasUselessControl(_ text: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    for (index, scalar) in scalars.enumerated() where index > 0 {
        let picture = scalars[index - 1]
        switch scalar.value {
        case 0xFE0F where picture.properties.isEmoji && picture.properties.isEmojiPresentation && picture.value > 0xFF: return true
        case 0xFE0F: break
        case 0xFE0E, 0x1F3FB...0x1F3FF:
            if picture.value > 0xFF, picture.properties.isEmoji, codeDrawing(String(picture)) == codeDrawing(String(picture) + String(scalar)) { return true }
        default: break
        }
    }
    return false
}
